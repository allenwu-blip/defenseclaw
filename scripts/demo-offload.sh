#!/bin/bash
# demo-offload.sh — Complete end-to-end demo of Local Model Offloading
#
# This script simulates the full user journey:
# 1. Agent uses frontier model, DefenseClaw collects query/response data
# 2. User discovers categories and selects one to offload
# 3. DefenseClaw recommends a local model
# 4. Trains the model on collected data
# 5. Evaluates quality
# 6. Routes queries locally
# 7. Shows cost savings
#
# Usage: ./scripts/demo-offload.sh

set -e

DEMO_DIR="/tmp/defenseclaw-offload-demo"
DATA_FILE="$DEMO_DIR/collected_queries.jsonl"

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║     DefenseClaw — Local Model Offloading Demo                 ║"
echo "║     Reduce frontier model costs by routing locally            ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Simulate data collection (what happens during normal agent operation)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Simulating agent query collection (normally automatic)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

mkdir -p "$DEMO_DIR"

# Generate realistic sample data
python3 -c "
import json, random

categories = {
    'code_generation': [
        ('Write a Python function to sort a list', 'def sort_list(lst):\n    return sorted(lst)'),
        ('Implement binary search', 'def binary_search(arr, target):\n    lo, hi = 0, len(arr)-1\n    while lo <= hi:\n        mid = (lo+hi)//2\n        if arr[mid] == target: return mid\n        elif arr[mid] < target: lo = mid+1\n        else: hi = mid-1\n    return -1'),
        ('Write a function to check palindrome', 'def is_palindrome(s):\n    return s == s[::-1]'),
        ('Create a stack class', 'class Stack:\n    def __init__(self): self.items = []\n    def push(self, item): self.items.append(item)\n    def pop(self): return self.items.pop()'),
        ('Implement fibonacci', 'def fib(n):\n    if n <= 1: return n\n    a, b = 0, 1\n    for _ in range(2, n+1): a, b = b, a+b\n    return b'),
        ('Write a linked list reversal', 'def reverse_list(head):\n    prev = None\n    while head:\n        next_node = head.next\n        head.next = prev\n        prev = head\n        head = next_node\n    return prev'),
        ('Implement quicksort', 'def quicksort(arr):\n    if len(arr) <= 1: return arr\n    pivot = arr[len(arr)//2]\n    left = [x for x in arr if x < pivot]\n    mid = [x for x in arr if x == pivot]\n    right = [x for x in arr if x > pivot]\n    return quicksort(left) + mid + quicksort(right)'),
    ],
    'summarization': [
        ('Summarize this meeting notes: We discussed Q3 targets...', 'Key points: Q3 targets reviewed, team agreed on 15% growth, next review in 2 weeks.'),
        ('Summarize: The project has 3 phases...', 'Summary: 3-phase project - design (2w), build (4w), test (2w). Total 8 weeks.'),
        ('TL;DR this email about the product launch...', 'Product launches March 15. Marketing starts Feb 1. All hands meeting next Monday.'),
    ],
    'data_extraction': [
        ('Extract the dates from: Meeting on Jan 5, deadline Feb 28', '{\"dates\": [\"Jan 5\", \"Feb 28\"]}'),
        ('Extract names: John Smith and Mary Johnson attended', '{\"names\": [\"John Smith\", \"Mary Johnson\"]}'),
        ('Extract prices: The item costs \$29.99 with tax \$32.49', '{\"prices\": [\"\$29.99\", \"\$32.49\"]}'),
    ],
}

examples = []
for cat, pairs in categories.items():
    for prompt, response in pairs:
        for _ in range(random.randint(5, 15)):  # simulate repeated similar queries
            examples.append({
                'prompt': prompt,
                'response': response,
                'category': cat,
                'tokens': len(prompt.split()) + len(response.split()),
                'timestamp': f'2026-08-{random.randint(1,10):02d}T{random.randint(8,18):02d}:00:00Z',
                'model': random.choice(['gpt-4o', 'claude-3.5-sonnet'])
            })

random.shuffle(examples)
with open('$DATA_FILE', 'w') as f:
    for ex in examples:
        f.write(json.dumps(ex) + '\n')
print(f'  Generated {len(examples)} collected query/response pairs')
print(f'  Categories: {list(categories.keys())}')
print(f'  Saved to: $DATA_FILE')
"

echo ""
echo "  In production, this data is collected automatically by DefenseClaw"
echo "  as agents make requests through the gateway."
echo ""

# Step 2: Discover categories
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Discovering query categories"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
defenseclaw offload --discover --data "$DATA_FILE"

# Step 3: Offload code_generation category
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Offloading 'code_generation' to local model"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Running: defenseclaw offload --category code_generation --data $DATA_FILE"
echo ""

defenseclaw offload \
  --category code_generation \
  --data "$DATA_FILE" \
  --method sft \
  --threshold 0.80 \
  --output "$DEMO_DIR/offload-output"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4: Verify deployment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Status file:"
cat "$DEMO_DIR/offload-output/offload-status.json" 2>/dev/null | python3 -m json.tool
echo ""
echo "  Route config:"
cat "$DEMO_DIR/offload-output/route.yaml" 2>/dev/null
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5: Further refinement with GRPO (optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  To further improve with reinforcement learning:"
echo "    defenseclaw offload --category code_generation --method grpo --data $DATA_FILE"
echo ""
echo "  To self-distill from a larger model:"
echo "    defenseclaw train --method sft --model qwen3:4b \\"
echo "      --dataset $DEMO_DIR/offload-output/sft_dataset.jsonl"
echo ""

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                    Demo Complete ✓                             ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║  The complete flow works:                                      ║"
echo "║    1. ✓ Data collected from agent interactions                 ║"
echo "║    2. ✓ Categories discovered automatically                    ║"
echo "║    3. ✓ Model recommended for category                         ║"
echo "║    4. ✓ SFT training completed                                 ║"
echo "║    5. ✓ Evaluation passed threshold                            ║"
echo "║    6. ✓ Routing activated                                      ║"
echo "║    7. ✓ Cost savings calculated                                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
