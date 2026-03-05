# Find Missing Boolean Columns
# Purpose: Identify correct column names for indicators that returned 0 booleans
# Date: 2026-02-10

library(tidyverse)
library(here)

# Load household data
hh_data <- readRDS(here("output", "wash_survey_hh_level.rds"))
all_cols <- names(hh_data)

# Indicators that returned 0 booleans:
# 2.3: Sanitation problems
# 2.6a: Open defecation - who
# 2.6b: Open defecation - when
# 4.1: Hygiene NFI problems

cat("=== Searching for missing boolean column patterns ===\n\n")

# 2.3: Sanitation problems - try related patterns
cat("2.3: Sanitation problems\n")
cat("Looking for patterns with 'sanitation' and 'problem':\n")
san_prob <- all_cols[str_detect(all_cols, "sanitation.*problem|problem.*sanitation")]
cat(paste("  -", san_prob, collapse = "\n"), "\n\n")

# 2.6a: Open defecation - who
cat("2.6a: Open defecation - who\n")
cat("Looking for patterns with 'groups' and 'practicing':\n")
od_who <- all_cols[str_detect(all_cols, "groups.*practicing|practicing.*defecation")]
cat(paste("  -", od_who, collapse = "\n"), "\n\n")

# 2.6b: Open defecation - when
cat("2.6b: Open defecation - when\n")
cat("Looking for patterns with 'when' and 'observed':\n")
od_when <- all_cols[str_detect(all_cols, "when.*observed|observed.*defecation")]
cat(paste("  -", od_when, collapse = "\n"), "\n\n")

# 4.1: Hygiene NFI problems
cat("4.1: Hygiene NFI problems\n")
cat("Looking for patterns with 'hygiene' and 'problem':\n")
hyg_prob <- all_cols[str_detect(all_cols, "hygiene.*problem|problem.*hygiene")]
cat(paste("  -", hyg_prob, collapse = "\n"), "\n\n")

# Check if these are actually summary columns that have separate boolean sets
cat("=== Checking for alternative boolean column patterns ===\n\n")

# Try shorter prefixes or follow-up question patterns
cat("Columns containing 'if_yes_which_ones':\n")
if_yes_which <- all_cols[str_detect(all_cols, "if_yes_which_ones")]
cat(paste("  -", if_yes_which, collapse = "\n"), "\n\n")

cat("Columns containing 'if_yes_select':\n")
if_yes_select <- all_cols[str_detect(all_cols, "if_yes_select")]
cat(paste("  -", if_yes_select, collapse = "\n"), "\n\n")
