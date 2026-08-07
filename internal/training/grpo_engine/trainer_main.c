/* trainer_main.c — Standalone GRPO training subprocess.
 * Communicates with Go parent via stdin/stdout binary protocol.
 * Runs parallel generation via GCD without Go signal handler interference.
 *
 * Protocol (all little-endian):
 *   Parent → Child:
 *     CMD_STEP (1 byte: 0x01) + prompt_len (4B) + prompt_tokens (4B each)
 *     CMD_REWARD (1 byte: 0x02) + G rewards (4B float each)
 *     CMD_QUIT (1 byte: 0xFF)
 *
 *   Child → Parent:
 *     RESP_TOKENS (1 byte: 0x01) + G (4B) + G×{len(4B) + tokens(4B each)}
 *     RESP_METRICS (1 byte: 0x02) + loss(4B float) + reward(4B float)
 *     RESP_READY (1 byte: 0x03)
 */
#include "grpo.h"
#include "tokenizer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#define CMD_STEP    0x01
#define CMD_REWARD  0x02
#define CMD_QUIT    0xFF
#define RESP_TOKENS  0x01
#define RESP_METRICS 0x02
#define RESP_READY   0x03

static int read_exact(int fd, void *buf, size_t n) {
    size_t done = 0;
    while (done < n) {
        ssize_t r = read(fd, (char *)buf + done, n - done);
        if (r <= 0) return -1;
        done += (size_t)r;
    }
    return 0;
}

static int write_exact(int fd, const void *buf, size_t n) {
    size_t done = 0;
    while (done < n) {
        ssize_t w = write(fd, (const char *)buf + done, n - done);
        if (w <= 0) return -1;
        done += (size_t)w;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: grpo-trainer <model.gguf> [G] [max_len] [lr] [clip_eps] [lora_rank]\n");
        return 1;
    }

    const char *model_path = argv[1];
    int G = argc > 2 ? atoi(argv[2]) : 4;
    int max_len = argc > 3 ? atoi(argv[3]) : 64;
    float lr = argc > 4 ? (float)atof(argv[4]) : 1e-4f;
    float clip_eps = argc > 5 ? (float)atof(argv[5]) : 0.2f;
    int lora_rank = argc > 6 ? atoi(argv[6]) : 8;

    float temp = 0.8f, top_p = 0.9f, kl_coef = 0.0f;

    /* Initialize engine */
    GrpoConfig cfg = {0};
    cfg.policy_gguf = model_path;
    cfg.max_seq_len = 2048;
    cfg.lora_rank = lora_rank;
    cfg.lora_alpha = lora_rank;
    cfg.lora_targets = "q,k,v,o,gate,up,down";
    cfg.num_threads = 12;
    cfg.memory_mode = 2; /* comfort */

    GrpoCtx *ctx = grpo_init(&cfg);
    if (!ctx) {
        fprintf(stderr, "grpo-trainer: init failed\n");
        return 1;
    }

    /* Signal ready */
    uint8_t resp = RESP_READY;
    write_exact(STDOUT_FILENO, &resp, 1);

    /* Main loop: read commands from stdin, write responses to stdout */
    int step_num = 0;
    int *flat_tokens = (int *)calloc((size_t)G * (size_t)max_len, sizeof(int));
    int *lengths = (int *)calloc((size_t)G, sizeof(int));

    while (1) {
        uint8_t cmd;
        if (read_exact(STDIN_FILENO, &cmd, 1) != 0) break;

        if (cmd == CMD_QUIT) break;

        if (cmd == CMD_STEP) {
            /* Read prompt */
            int32_t prompt_len;
            if (read_exact(STDIN_FILENO, &prompt_len, 4) != 0) break;
            int *prompt = (int *)malloc((size_t)prompt_len * sizeof(int));
            if (read_exact(STDIN_FILENO, prompt, (size_t)prompt_len * 4) != 0) {
                free(prompt);
                break;
            }

            /* Generate G completions (parallel via GCD) */
            GrpoCompletion *comps = (GrpoCompletion *)calloc((size_t)G, sizeof(GrpoCompletion));
            float *old_lp = (float *)calloc((size_t)G * (size_t)max_len, sizeof(float));
            for (int g = 0; g < G; g++) {
                comps[g].tokens = flat_tokens + g * max_len;
                comps[g].logprobs = old_lp + g * max_len;
                comps[g].len = 0;
            }

            /* Prefill (full OMP) + parallel generate (GCD + _st kernels) */
            grpo_generate_parallel(ctx, prompt, prompt_len, G, max_len, temp, top_p, comps);

            for (int g = 0; g < G; g++)
                lengths[g] = comps[g].len;

            /* Send tokens to parent */
            resp = RESP_TOKENS;
            write_exact(STDOUT_FILENO, &resp, 1);
            int32_t g_val = G;
            write_exact(STDOUT_FILENO, &g_val, 4);
            for (int g = 0; g < G; g++) {
                int32_t len = lengths[g];
                write_exact(STDOUT_FILENO, &len, 4);
                write_exact(STDOUT_FILENO, flat_tokens + g * max_len, (size_t)len * 4);
            }

            /* Wait for rewards from parent */
            uint8_t rcmd;
            if (read_exact(STDIN_FILENO, &rcmd, 1) != 0 || rcmd != CMD_REWARD) {
                free(prompt); free(comps); free(old_lp);
                break;
            }
            float *rewards = (float *)malloc((size_t)G * sizeof(float));
            if (read_exact(STDIN_FILENO, rewards, (size_t)G * 4) != 0) {
                free(prompt); free(comps); free(old_lp); free(rewards);
                break;
            }

            /* Compute advantages */
            float mean_r = 0, std_r = 0;
            for (int g = 0; g < G; g++) mean_r += rewards[g];
            mean_r /= (float)G;
            for (int g = 0; g < G; g++) std_r += (rewards[g]-mean_r)*(rewards[g]-mean_r);
            std_r = sqrtf(std_r / (float)G);
            if (std_r < 1e-8f) std_r = 1e-8f;
            float *advantages = (float *)malloc((size_t)G * sizeof(float));
            for (int g = 0; g < G; g++)
                advantages[g] = (rewards[g] - mean_r) / std_r;

            /* Policy logprobs (sequential, full OMP) */
            int max_actual = 0;
            for (int g = 0; g < G; g++)
                if (lengths[g] > max_actual) max_actual = lengths[g];

            float *policy_lp = (float *)calloc((size_t)G * (size_t)max_actual, sizeof(float));
            float *ref_lp = (float *)calloc((size_t)G * (size_t)max_actual, sizeof(float));

            for (int g = 0; g < G; g++) {
                int seq_len = prompt_len + lengths[g];
                int *full_seq = (int *)malloc((size_t)seq_len * sizeof(int));
                memcpy(full_seq, prompt, (size_t)prompt_len * sizeof(int));
                memcpy(full_seq + prompt_len, flat_tokens + g * max_len,
                       (size_t)lengths[g] * sizeof(int));
                float *lp_out = (float *)calloc((size_t)seq_len, sizeof(float));
                grpo_policy_logprobs(ctx, full_seq, seq_len, lp_out);
                for (int t = 0; t < lengths[g] && t < max_actual; t++)
                    policy_lp[g * max_actual + t] = lp_out[prompt_len + t];
                free(lp_out);
                free(full_seq);
            }

            /* Backward + Adam */
            step_num++;
            grpo_backward(ctx, advantages, policy_lp, old_lp, ref_lp,
                         G, max_actual, clip_eps, kl_coef);
            grpo_adam_step(ctx, lr, 0.9f, 0.999f, 1e-8f, step_num);

            /* Send metrics */
            resp = RESP_METRICS;
            write_exact(STDOUT_FILENO, &resp, 1);
            GrpoStats stats = grpo_stats(ctx);
            float loss = stats.last_loss;
            write_exact(STDOUT_FILENO, &loss, 4);
            write_exact(STDOUT_FILENO, &mean_r, 4);

            /* Checkpoint every 10 steps */
            if (step_num % 10 == 0) {
                char cp_path[256];
                snprintf(cp_path, sizeof(cp_path), "/tmp/grpo-checkpoint-%d.dclora", step_num);
                grpo_save_lora(ctx, cp_path);
                fprintf(stderr, "[grpo-trainer] checkpoint at step %d\n", step_num);
            }

            free(prompt); free(comps); free(old_lp);
            free(rewards); free(advantages); free(policy_lp); free(ref_lp);
        }
    }

    free(flat_tokens); free(lengths);
    grpo_free(ctx);
    return 0;
}
