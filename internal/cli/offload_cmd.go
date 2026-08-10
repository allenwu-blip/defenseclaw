//go:build cgo && grpo_engine

// Copyright 2026 Cisco Systems, Inc. and its affiliates
// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"os"

	"github.com/defenseclaw/defenseclaw/internal/training"
	"github.com/spf13/cobra"
)

var offloadCmd = &cobra.Command{
	Use:   "offload",
	Short: "Offload query categories from frontier models to local models",
	Long: `Analyze collected query data, train a local model, and route specific
categories locally — eliminating frontier model token costs for those queries.

The complete flow:
  1. Discovers categories from collected query/response data
  2. Recommends the best local model for the selected category
  3. Trains the model (SFT or GRPO) on collected data
  4. Evaluates quality against a threshold
  5. Activates local routing for that category
  6. Reports cost savings

Examples:
  # See what categories are available
  defenseclaw offload --discover --data ~/.defenseclaw/audit/queries.jsonl

  # Offload code generation to a local model (auto-recommends)
  defenseclaw offload --category code_generation --data queries.jsonl

  # Offload with specific model choice
  defenseclaw offload --category summarization --model qwen2.5:7b --data queries.jsonl

  # Refine with GRPO after initial SFT
  defenseclaw offload --category code_generation --method grpo --data queries.jsonl`,
	RunE: runOffload,
}

var (
	offloadData      string
	offloadCategory  string
	offloadModel     string
	offloadMethod    string
	offloadOutput    string
	offloadDiscover  bool
	offloadThreshold float64
	offloadAutoRoute bool
)

func init() {
	offloadCmd.Flags().StringVar(&offloadData, "data", "", "Path to collected query/response JSONL")
	offloadCmd.Flags().StringVar(&offloadCategory, "category", "", "Category to offload")
	offloadCmd.Flags().StringVar(&offloadModel, "model", "", "Local model (auto-recommended if empty)")
	offloadCmd.Flags().StringVar(&offloadMethod, "method", "sft", "Training method: sft, grpo")
	offloadCmd.Flags().StringVar(&offloadOutput, "output", "./offload-output", "Output directory")
	offloadCmd.Flags().BoolVar(&offloadDiscover, "discover", false, "Discover available categories")
	offloadCmd.Flags().Float64Var(&offloadThreshold, "threshold", 0.80, "Minimum eval score to deploy (0.0-1.0)")
	offloadCmd.Flags().BoolVar(&offloadAutoRoute, "auto-route", true, "Automatically activate routing after training")
	offloadCmd.MarkFlagRequired("data")

	rootCmd.AddCommand(offloadCmd)
}

func runOffload(cmd *cobra.Command, args []string) error {
	if _, err := os.Stat(offloadData); err != nil {
		return fmt.Errorf("data file not found: %s\n\n"+
			"DefenseClaw collects query data during normal operation.\n"+
			"Data format (JSONL):\n"+
			"  {\"prompt\":\"...\",\"response\":\"...\",\"category\":\"code_generation\",\"tokens\":150}\n\n"+
			"To generate sample data: defenseclaw offload --generate-sample",
			offloadData)
	}

	// Discovery mode
	if offloadDiscover {
		return discoverCategories()
	}

	// Need category for offloading
	if offloadCategory == "" {
		// Show categories and ask user to pick
		return discoverCategories()
	}

	// Auto-recommend model if not specified
	if offloadModel == "" {
		categories, err := training.DiscoverCategories(offloadData)
		if err != nil {
			return err
		}
		var stats training.CategoryStats
		for _, c := range categories {
			if c.Name == offloadCategory {
				stats = c
				break
			}
		}
		recs := training.RecommendModel(offloadCategory, stats)
		if len(recs) == 0 {
			return fmt.Errorf("no model recommendations for category '%s'", offloadCategory)
		}

		fmt.Printf("\n📋 Model Recommendations for '%s':\n\n", offloadCategory)
		for i, r := range recs {
			marker := "  "
			if i == 0 {
				marker = "→ "
			}
			fmt.Printf("  %s%-18s (score: %.0f%%) — %s\n", marker, r.Model, r.Score*100, r.Reason)
		}
		fmt.Printf("\n  Using recommended: %s\n", recs[0].Model)
		fmt.Printf("  Override with: --model <name>\n\n")
		offloadModel = recs[0].Model
	}

	// Run the complete offload pipeline
	cfg := training.OffloadConfig{
		AuditDBPath:   offloadData,
		Category:      offloadCategory,
		Model:         offloadModel,
		Method:        offloadMethod,
		OutputDir:     offloadOutput,
		MinExamples:   10,
		EvalThreshold: offloadThreshold,
		EvalSamples:   20,
		AutoRoute:     offloadAutoRoute,
	}

	fmt.Printf("╔═══════════════════════════════════════════════════════════╗\n")
	fmt.Printf("║       Local Model Offloading                              ║\n")
	fmt.Printf("╠═══════════════════════════════════════════════════════════╣\n")
	fmt.Printf("║  Category:  %s\n", offloadCategory)
	fmt.Printf("║  Model:     %s\n", offloadModel)
	fmt.Printf("║  Method:    %s\n", offloadMethod)
	fmt.Printf("║  Threshold: %.0f%%\n", offloadThreshold*100)
	fmt.Printf("║  Output:    %s\n", offloadOutput)
	fmt.Printf("╚═══════════════════════════════════════════════════════════╝\n")

	status, err := training.RunOffload(context.Background(), cfg)
	if err != nil {
		return err
	}

	if status != nil && status.Phase == "done" {
		fmt.Printf("\n═══════════════════════════════════════════════════════════\n")
		fmt.Printf("  Status:       ✅ DEPLOYED\n")
		fmt.Printf("  Category:     %s → local %s\n", status.Category, status.Model)
		fmt.Printf("  Eval score:   %.1f%%\n", status.EvalScore*100)
		fmt.Printf("  Token savings: %d tokens/month\n", status.TokensSaved)
		fmt.Printf("  Cost savings:  $%.2f/month\n", status.CostSavings)
		fmt.Printf("═══════════════════════════════════════════════════════════\n")
	}
	return nil
}

func discoverCategories() error {
	categories, err := training.DiscoverCategories(offloadData)
	if err != nil {
		return err
	}

	if len(categories) == 0 {
		return fmt.Errorf("no categories found in %s. Collect more query data first.", offloadData)
	}

	fmt.Printf("\n📊 Discovered Categories (from %s)\n\n", offloadData)
	fmt.Printf("  %-20s  %8s  %8s  %10s  %s\n", "CATEGORY", "QUERIES", "AVG TOK", "EST COST", "STATUS")
	fmt.Printf("  %-20s  %8s  %8s  %10s  %s\n", "────────", "───────", "───────", "────────", "──────")

	for _, c := range categories {
		status := "ready"
		if c.TotalQueries < 10 {
			status = "need more data"
		}
		fmt.Printf("  %-20s  %8d  %8d  $%8.2f  %s\n",
			c.Name, c.TotalQueries, c.AvgTokens, c.TokenCost, status)
	}

	fmt.Printf("\n  To offload a category:\n")
	fmt.Printf("    defenseclaw offload --category <name> --data %s\n\n", offloadData)
	return nil
}
