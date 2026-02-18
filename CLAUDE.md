# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an R tidyverse project for analyzing WASH (Water, Sanitation, and Hygiene) survey data collected from IDP (Internally Displaced Persons) camps in the Tawila region, North Darfur, Sudan. The assessment covers four camps (A, B, C, D) with a total population of 95,696 individuals.

## Survey Design

**Target Sample Size**: 652 households across 35 clusters
- Camp A: 160 HH (8 clusters, ~20 HH/cluster)
- Camp B: 168 HH (8 clusters, ~21 HH/cluster)
- Camp C: 104 HH (8 clusters, ~13 HH/cluster)
- Camp D: 220 HH (11 clusters, ~20 HH/cluster)

**Sampling Method**: Stratified systematic cluster sampling
- Camps serve as strata
- Systematic sampling intervals (k values): 21, 21, 20, 32 for camps A-D respectively
- Design Effect (DEFF): 2.0
- Effective sample size: 326 (actual n / DEFF)

**Precision Targets**:
- Overall Tawila-wide: ±5.4% margin of error at 95% confidence
- Camp-level: ±9-14% margin of error at 95% confidence

## Critical Statistical Constraints

### What Can Be Measured
- Overall Tawila-wide trends (±5.4% MoE)
- Camp-specific estimates (±9-14% MoE)
- Differences between camps ≥20 percentage points
- Sphere Standard compliance when >15 points from threshold

### What Cannot Be Measured
- Subgroup analysis within individual camps (subsample MoE >25%)
- Rare events (<10% prevalence)
- Small differences between camps (<15 percentage points)
- Year-over-year changes <15 percentage points

**Important**: Subgroup analyses (recent arrivals, households with disabled members, etc.) should ONLY be conducted at the Tawila-wide level, never disaggregated by individual camps.

## Analysis Approach

### Complex Survey Design Handling
All analyses MUST account for the cluster sampling design using design effect adjustment:

```r
library(survey)
library(srvyr)

# Create survey design object
survey_design <- data %>%
  as_survey_design(
    strata = camp,
    ids = cluster_id,
    weights = sampling_weight,
    fpc = finite_pop_correction  # if applicable
  )

# Calculate weighted estimates with correct standard errors
survey_design %>%
  group_by(camp) %>%
  summarise(
    prop = survey_mean(indicator, vartype = "ci"),
    .groups = "drop"
  )
```

Never use simple `mean()` or `prop.table()` without survey design adjustment, as this will produce incorrect standard errors and confidence intervals.

### Margin of Error Reporting
Always report confidence intervals alongside point estimates. Use the effective sample size (n/DEFF) for MoE calculations:

```r
# Margin of Error formula
moe <- 1.96 * sqrt(0.25 / effective_n)
```

### Weighting
- Self-weighting design due to proportional allocation
- Post-stratification weights may be needed if non-response varies significantly by camp
- Check for non-response patterns before assuming equal weights

## Data Structure Expectations

**Dual-level dataset structure** (from single Kobo form via `/data.json` endpoint):

1. **Household level**: 369 consented households × 233 columns
   - File: `output/wash_survey_hh_level.xlsx` and `.rds`
   - Main demographics, WASH indicators, all survey questions
   - Created via Kobo Export API with `lang="English (en)"` and `multiple_select="both"`
   - Arabic free-text integrated from `data/wash_survey_arabic_content_final.xlsx`

2. **Container level**: 867 water containers × 23 columns
   - File: `output/wash_survey_container_level.xlsx` and `.rds`
   - Expanded from `container_repeat` groups (nested in household records)
   - Each container includes 11 household context fields + 10 container-specific fields
   - Used for derived indicators 1.7 and 1.8 (liters per person per day analysis)

**Key technical details:**
- Consent filtering applied BEFORE repeat group expansion (prevents invalid data)
- Container `index` field created via `row_number()` (Kobo doesn't provide `_index`)
- `fill_level` converted to numeric (1.0, 0.75, 0.5, 0.25) for calculations
- Boolean columns: format `{parent}_{choice}` with underscore (R-compatible)

**Reference materials**:
- `reference/indicators_processing_guide.md` - Complete specifications for all 41 indicators (validated against survey)
- `reference/SDN_Tawila_Survey_ToR_20260120.md` - Terms of Reference with Annex 1
- Survey form files: `data/survey.xlsx`, `data/choices.xlsx` - Kobo XLSForm definitions

## Current Implementation Status

**Analysis script**: `wash_survey_analysis.R` (2,970 lines, single self-contained file)

### Completed Indicators (38 of 41)

**Table 2: WASH Theme Indicators** (29 active + 3 data gaps)
- **Water (1.1-1.9)**: 7 indicators ✓ (1.2 split into 1.2 + 1.2.1) + 2 derived (container analysis)
  - Color: `#28A1d2` (blue), `#009999` (teal for sufficient), `#e36159` (red for insufficient)
  - Outputs: `wash_survey_water_indicators.xlsx`, 7 PNG plots
- **Sanitation (2.1-3.0)**: 10 indicators ✓
  - Color: `#008d48` (green)
  - Outputs: `wash_survey_sanitation_indicators.xlsx`, 12 PNG plots
- **Hygiene (4.1-4.11)**: 9 indicators ✓ + 2 data gaps (4.4, 4.10)
  - Color: `#532F87` (purple)
  - Outputs: `wash_survey_hygiene_indicators.xlsx`, 9 PNG plots
- **Public Health (5.1)**: 1 data gap (morbidity not collected)
- **Priorities (7.1-7.2)**: 2 indicators ✓
  - Color: `#009999` (GWC teal)
  - Outputs: `wash_survey_priorities_indicators.xlsx`, 2 PNG plots

**Table 1: Disaggregation Indicators** (9 indicators ✓)
- Camp distribution, demographics, vulnerability subgroups
- Outputs: `wash_survey_disaggregation_indicators.xlsx`, 10 PNG plots

**Total outputs**: 39 PNG plots + 5 Excel files + 2 data files (HH + container)

### Survey Design Implementation

**Pseudo-clustering approach** (no actual cluster IDs collected):
```r
# Create pseudo-clusters from camp + respondent age
wash_data <- wash_data %>%
  mutate(
    pseudo_cluster = paste0(
      camp_name, "_cluster_",
      cut(as.numeric(age_of_hh_respondent),
          breaks = seq(15, 85, by=5),
          labels = FALSE)
    )
  )

# Create survey design
survey_design <- wash_data %>%
  as_survey_design(
    strata = camp_name,
    ids = pseudo_cluster,
    weights = weight,  # Equal weights (1) for self-weighting design
    nest = TRUE
  )
```

**Key implementation decisions:**
- Equal weights (all households weight = 1) due to proportional allocation
- Pseudo-clusters based on age groups within camps (best available approximation)
- All indicators use `survey_mean(vartype = "ci")` for proper standard errors

## Common Packages

```r
# Core tidyverse
library(tidyverse)     # Data manipulation and visualization
library(readxl)        # Excel file import
library(writexl)       # Excel export (no Java dependency)

# Survey analysis
library(srvyr)         # Tidyverse-compatible survey functions (wraps survey package)

# Data processing
library(httr)          # Kobo API calls
library(yaml)          # Config file reading
library(here)          # Project-relative paths
library(janitor)       # make_clean_names() for column standardization
library(jsonlite)      # Parse /data.json endpoint
library(glue)          # String interpolation

# Reporting
library(scales)        # Format percentages and numbers in plots
```

**Note**: The `survey` package is loaded automatically by `srvyr` - no need to load both.

## Development Environment

**Language Server Protocol (LSP)**: This environment uses Serena MCP server for R and Python LSP functionality through the Model Context Protocol. Do not suggest installing `python-lsp-server`, `pylsp`, or other LSP libraries - Serena provides all necessary code intelligence features.

## Shared Resources

This project is part of a larger collection of UNHCR Information Management tools. Shared utility functions are available in:

- `../_common/functions.R` - Common functions used across multiple projects
  - `make_shelter_table()` - Pivot and summarize categorical data
  - `make_time_displacement_table()` - Summarize temporal patterns
  - `make_reasons_table()` - Process multi-select reason questions
  - `make_places_table()` - Aggregate location data with percentages

Source these functions when needed rather than duplicating code.

## Main Script Structure

**File**: `wash_survey_analysis.R` (single self-contained script, 2,970 lines)

**Structure:**
1. **Header & Libraries** (lines 1-35): Purpose, packages, color palettes
2. **Configuration** (36-40): Kobo credentials from `config.yaml`
3. **Data Import - Household Level** (41-150): Kobo Export API with English labels
4. **Data Import - Container Level** (151-320): `/data.json` endpoint, repeat group expansion
5. **Boolean Processing** (175-230): Binary→multi-select pairs, "No" response creation
6. **Survey Design Setup** (389-632): Pseudo-clusters, equal weights, design object
7. **Water Indicators** (636-1120): 1.1-1.9 (6 active + helper function)
8. **Sanitation Indicators** (1123-1880): 2.1-3.0 (10 active + helper function)
9. **Hygiene Indicators** (1882-2533): 4.1-4.11 (9 active, 2 gaps + helper function)
10. **Public Health** (2535-2545): 5.1 (data gap, commented placeholder)
11. **Priorities Indicators** (2547-2689): 7.1-7.2 (2 active)
12. **Disaggregation Indicators** (2691-2970): Table 1 (9 indicators)

**No external scripts** - All functions defined inline for self-containment.

**Key helper functions:**
- `create_water_bar_plot()` - Standardized water indicator plots (blue)
- `create_sanitation_bar_plot()` - Standardized sanitation indicator plots (green)
- `create_hygiene_bar_plot()` - Standardized hygiene indicator plots (purple)

## Data Processing Details

### Kobo Data Cleaning

**Column removal order:**
1. Move `index` to first position with `relocate(index)`
2. Remove columns 2-3 (original first two columns from Kobo)
3. Remove all columns from `id` onwards (consecutive metadata at end)

**Survey administration columns removed:**
- Organization-specific columns (IRC, TGH, SCI, SI identifiers)
- Consent prompts and GPS coordinate components
- Long survey introduction text

### Arabic Content Extraction

**Patterns for free-text Arabic columns:**
- `^if_other` - "Other, specify" follow-ups
- `^if_others` - Alternative "Others" pattern
- `^comments` - Comment fields
- `^hh_fc_7_1_is_there_anything_else` - Final open-ended question

**Output:** `output/wash_survey_arabic_content.xlsx` - filtered to rows with non-empty content

### Expected Warnings

**Excel export warnings (safe to ignore):**
- "unrecognized data type" for `attachments`, `geolocation`, `tags`, `notes` - Kobo system metadata in list format

**Indicator 1.6 warning (expected):**
- "Categories sum to 106%, expected ~100%" - Multi-select question allows overlapping responses

## Critical Patterns and Lessons Learned

### 1. Boolean Column Conversion - ALWAYS Guard with `where()`

**THE PROBLEM:** Using `across()` with prefix selectors like `starts_with()` can destroy text columns that share the same prefix:

```r
# DANGEROUS - Will convert ALL columns starting with prefix, including text columns
wash_data <- wash_data %>%
  mutate(across(
    starts_with("hh_s_"),
    ~ as.numeric(.x)
  ))
# Result: Text columns like "hh_s_2_1_..." become NA, destroying data
```

**THE SOLUTION:** Always guard with `where()` to only convert actual boolean columns:

```r
# SAFE - Only converts columns that are actually numeric or "0"/"1" strings
wash_data <- wash_data %>%
  mutate(across(
    starts_with("hh_s_") &
      where(~ is.numeric(.x) || (is.character(.x) && all(na.omit(.x) %in% c("0", "1")))),
    ~ as.numeric(.x)
  ))
```

**When this pattern is used:**
- Sanitation indicators: lines 1134-1141 (guards `starts_with("hh_s_")`, `starts_with("if_yes_select_multiple_")`, `starts_with("hh_swm_")`)
- Hygiene indicators: lines 1888-1895 (guards `starts_with("hh_h_")`, `starts_with("if_yes_which_ones_")`, `starts_with("during_your_last_")`)

**Why it matters:** Parent select_one text columns (like "Yes"/"No") often share the same prefix as their child boolean columns. Without the guard, you'll silently destroy these text columns and create empty indicators.

### 2. Multi-Select with Parent Yes/No Gate

**Pattern:** When Kobo has a parent Yes/No question followed by conditional multi-select, include the parent "No" response as a category:

```r
# Create boolean column for "No" responses
boolean_col <- paste0(multiselect_col, "_no")
wash_data <- wash_data %>%
  mutate(
    !!boolean_col := if_else(
      .data[[binary_col]] != trigger_value,
      1,
      0
    )
  )
```

**Examples:**
- Water problems (1.3): Parent "Do you have problems?" → Multi-select "Which ones?" + "No" category
- Sanitation problems (2.3): Same pattern
- Hygiene NFI problems (4.1): Same pattern

**Kobo XLSForm pattern**: Lines 175-189 define all binary→multi-select pairs processed during data import

### 3. Actual Kobo Category Values vs. Expected

**Always verify actual values before coding factor levels:**

```r
# Check actual values first
table(data$field_name, useNA = "ifany")
```

**Examples where guide was incorrect:**
- **4.5 Satisfaction**: Data has "Unsatisfied"/"Very unsatisfied" NOT "Dissatisfied"/"Very dissatisfied"
- **4.3 Spending**: SDG ranges are 0-10K, 10-20K, 21-40K (thousands), not 1-1K, 1-3K (hundreds)
- **4.11 Menstrual**: Includes "Not menstruating" and "Don't know" - must filter to Yes/No only
- **7.1 Priorities**: Full English sentences as values, not short snake_case codes

### 4. Survey-Weighted Calculation Pattern

**Standard pattern for all indicators:**

```r
indicator_X.X <- tryCatch({

  # For categorical (group_by response):
  results <- survey_design %>%
    group_by(category = field_name) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      .groups = "drop"
    ) %>%
    filter(!is.na(category)) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))

  # For boolean (calculate proportion):
  results <- survey_design %>%
    summarise(
      field_name = col,
      estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100,
      n_unweighted = unweighted(sum(coalesce(!!sym(col), 0) == 1))
    ) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)

  # Plot + save
  plot <- create_*_bar_plot(data = results, ...)
  ggsave(here("output", "plots", "indicator_X.X.png"), plot, ...)

  message("  [OK] Indicator X.X: Description")
  return(results)

}, error = function(e) {
  message("  [ERROR] Indicator X.X: ", e$message)
  return(NULL)
})
```

**Key points:**
- Always use `survey_mean(vartype = "ci")` NOT `mean()` or `summarise(n())`
- Multiply by 100 for percentages AFTER survey calculation
- Use `unweighted(n())` or `unweighted(sum())` for sample sizes
- Round percentages and CIs after calculation
- Wrap in `tryCatch()` with descriptive error messages

### 5. Plot Styling Standards

**Stacked bar charts** (categorical indicators like 1.6, 1.9, 4.3, 4.5):
- Add white borders between segments: `color = "white", linewidth = 1.5`
- Use `position = "stack"` with `position_stack(vjust = 0.5)` for centered labels
- Define manual color scales for diverging (Likert) or sequential (ranges) data

**Grouped bar charts** (multi-select, boolean indicators):
- Use helper functions: `create_water_bar_plot()`, `create_sanitation_bar_plot()`, `create_hygiene_bar_plot()`
- Error bars in softer grey: `#888888` (not black)
- Label position: `"outside"` for most, `"inside"` for very high percentages
- Consistent subtitle format: `glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)")`

**Color palette** (Global WASH Cluster):
```r
GWC_PALETTE_WATER_SANITATION_HYGIENE <- c("#28A1d2", "#532F87", "#008d48")
# Water: #28A1d2 (blue)
# Hygiene: #532F87 (purple)
# Sanitation: #008d48 (green)
# Priorities: #009999 (GWC teal)
```

### 6. Conditional Analysis (Filtered Denominators)

**Pattern for indicators conditional on previous response:**

Example: 4.9.2 Soap Barriers (only asked if 4.9.1 = "No"):

```r
# Filter to specific denominator
soap_field <- "hh_h_4_2_2_do_you_have_enough_soap..."
no_soap_data <- wash_data %>%
  filter(!!sym(soap_field) == "No")

# Create NEW survey design from filtered data
no_soap_design <- no_soap_data %>%
  as_survey_design(
    strata = camp_name,
    ids = pseudo_cluster,
    weights = weight,
    nest = TRUE
  )

# Calculate on filtered design
results <- map_dfr(barrier_cols, function(col) {
  no_soap_design %>%
    summarise(...)
})
```

**Key insight:** Must recreate survey design object from filtered data - cannot just filter the existing design.

### 7. Age Group Creation for Disaggregation

**Standard age grouping pattern** (for 4.11, disaggregation indicators):

```r
data <- data %>%
  mutate(
    age_numeric = as.numeric(age_of_hh_respondent),
    age_group = case_when(
      age_numeric >= 15 & age_numeric <= 24 ~ "15-24",
      age_numeric >= 25 & age_numeric <= 34 ~ "25-34",
      age_numeric >= 35 & age_numeric <= 44 ~ "35-44",
      age_numeric >= 45 & age_numeric <= 54 ~ "45-54",
      TRUE ~ NA_character_
    )
  )
```

**For elderly counts (disaggregation indicators):** Handle outliers by capping at reasonable maximum (e.g., >4 elderly → NA)

### 8. Survey_mean() NA Handling for Percentage Calculations

**CRITICAL:** When calculating percentages that should sum to 100%, explicitly handle NAs instead of using `na.rm = TRUE`:

**The Problem:**
```r
# WRONG - Excludes NAs from denominator
survey_mean(
  field == "value",
  vartype = "ci", na.rm = TRUE
) * 100
```
This calculates percentage among non-NA records only, not total population. For stacked bars or complete category breakdowns, percentages won't sum to 100%.

**The Solution:**
```r
# CORRECT - Includes all records in denominator
survey_mean(
  !is.na(field) & field == "value",
  vartype = "ci"
) * 100
```
The `!is.na()` check ensures NAs count as FALSE (not matching condition), including them in the denominator.

**When this matters:** Indicator 1.2.1 has `if_no_then_what_needs_are_not_covered` with 172 NAs (answered "Yes" to sufficiency) + 197 non-NAs (answered "No"). Using `na.rm = TRUE` would calculate insufficient categories as % of 197 instead of 369, making them sum to 100% alone.

### 9. Indicator 1.2 Split: Stacked vs. Standard Bar Charts

**Water sufficiency was split into two separate indicators:**

**Indicator 1.2 (Drinking/Cooking):**
- Simple Yes/No stacked horizontal bar
- Format: Single bar with segments (Yes: 64% teal, No: 36% red)
- Size: 8×3 inches
- Use case: Binary outcome with clear majority

**Indicator 1.2.1 (Other Domestic Purposes):**
- Standard horizontal bar chart (NOT stacked)
- 5 separate bars with full descriptive labels
- Format: Each category on y-axis with percentage on x-axis
- Size: 10×5 inches for label readability
- Use case: Multiple categories with long descriptive labels

**Key lesson:** Stacked bars work well for simple binary outcomes but become unreadable with long category labels. Use standard horizontal bars when descriptive labels are important or when you have 3+ categories with varying lengths.

**Descriptive labels example:**
```r
display_label = c(
  "Enough for other domestic purposes\n(bathing, washing)",
  "Not enough for drinking, cooking\nand washing/bathing/general use",
  "Not enough for basic needs",
  "Not enough for drinking",
  "Not enough for cooking"
)
```

## R Coding Preferences

### Vectorization Over Loops

Prefer `purrr` functional programming over explicit loops:

```r
# Prefer
results <- items %>% keep(~ condition(.x))

# Avoid
results <- character()
for (item in items) {
  if (condition(item)) results <- c(results, item)
}
```

### Code Section Headers for RStudio Navigation

Use RStudio-compatible section headers with minimum 4 dashes to enable code folding and outline navigation:

**Main sections** (top-level in outline):
```r
# ______________________________________________________________________________
# SECTION 1: DESCRIPTIVE TITLE ----
# ______________________________________________________________________________
# Purpose: What this section does
# Output: What it produces
# ______________________________________________________________________________
```

**Subsections** (nested in outline):
```r
## ---- Subsection Title ----
```

**Function headers** (also appear in outline):
```r
## ---- Helper Function: Function Purpose ----
```

This creates a navigable structure in RStudio's document outline panel and enables code section folding.

## Key Analysis Considerations

### Sphere Standards Comparison
When comparing against humanitarian standards:
- Report point estimate, confidence interval, AND interpretation
- If CI spans the threshold, state "cannot definitively conclude standard is met"
- Example: "55% access (95% CI: 49.6%-60.4%) cannot definitively meet 50% threshold"

### Between-Camp Comparisons
Always test whether confidence intervals overlap before claiming differences:
```r
# Good approach
camp_estimates %>%
  mutate(
    ci_lower = estimate - 1.96 * std_error,
    ci_upper = estimate + 1.96 * std_error
  ) %>%
  # Then manually check for overlap between camps
```

### Missing Data
- Report non-response rates by camp
- Investigate patterns in missing data (MCAR vs MAR vs MNAR)
- Consider post-stratification weighting if response rates vary by camp

## Quality Checks

Always verify:
1. Sample sizes match design (652 total, correct allocation per camp)
2. All GPS coordinates fall within camp boundaries
3. Cluster sizes range 13-21 HH
4. Missing data <5% for key indicators
5. Design effect calculated from actual data is close to assumed DEFF=2.0
6. Confidence intervals reported for all estimates

## Output Standards

All result tables must include:
- Point estimate (percentage or mean)
- 95% confidence interval
- Sample size (actual and effective)
- Margin of error

Example format:
```
| Indicator | Camp A | Camp B | Camp C | Camp D | Overall |
|-----------|--------|--------|--------|--------|---------|
| Access to basic water | 55% (44-66%) | 62% (51-73%) | 48% (34-62%) | 70% (61-79%) | 63% (58-68%) |
| n (effective) | 160 (80) | 168 (84) | 104 (52) | 220 (110) | 652 (326) |
```

## Git Workflow

**Branch structure:**
- `main` - Stable, production-ready code
- `development` - Active development branch (current)

**Merge strategy:** All features developed on `development`, merged to `main` via `--no-ff` (preserves feature history)

**Recent commits:**
- `45afc0e` - Merge: Complete Table 2 indicators (hygiene + priorities)
- `b08605e` - docs: update indicators processing guide with final count
- `e64fe37` - feat: implement hygiene, public health, and priorities indicators
- `e916e75` - fix: restore 4 missing sanitation indicators by guarding boolean conversion
- `905c569` - Merge: Fix Indicator 1.9 and improve plot visibility

## What Remains To Be Done

### Derived Indicators (Container Analysis)

**Indicators 1.7 & 1.8** - Not yet implemented:
- 1.7: % of HH with <15 liters per person per day (Sphere standard)
- 1.8: Average liters per person per day by camp

**Data available**: Container-level dataset (867 rows × 23 columns) includes:
- `volume_liters` - Container capacity (character, needs parsing)
- `number_of_containers` - How many of this type (character, needs parsing)
- `frequency_filled` - How often filled (needs conversion to daily rate)
- `fill_level` - Current fill (numeric: 1.0, 0.75, 0.5, 0.25)
- `total_no_of_people_in_hh` - From household context

**Challenges:**
- Volume parsing: "20-25 liters", "Between 10 and 20 liters", "5 liter", etc.
- Frequency conversion: "Once a day", "Twice a day", "Once every 2 days", etc.
- Multiple containers per household need aggregation
- Partial fills need to be accounted for

**Reference available**: `reference/example_gaza_container_analysis/` - Similar calculation approach

### Potential Future Work

1. **Camp-level disaggregation**: Current implementation shows overall Tawila-wide estimates only. Could add camp-specific breakdowns for key indicators (where sample size permits).

2. **Subgroup analysis**: Disaggregate key indicators by vulnerability groups (PLW, disabled, children <5, elderly) at Tawila-wide level.

3. **Cross-tabulation**: Analyze relationships between indicators (e.g., water access × FRC levels, soap access × handwashing practices).

4. **Report generation**: Automated markdown/Word report generation from analysis results.

## Project Context

This project is part of humanitarian information management work for UNHCR Mozambique operations, though the specific assessment is for Sudan. Related projects in the parent directory include:
- Mozambique cholera response monitoring
- HPM (Humanitarian Performance Monitoring)
- Various 5W (Who, What, Where, When, for Whom) consolidation tools
- Emergency response assessments

Code style and patterns should align with the organizational standards established across these projects.

## Quick Reference: Common Tasks

**Run full analysis:**
```bash
Rscript wash_survey_analysis.R
```

**Run container L/P/D artifact-filtered analysis:**
```bash
Rscript container_lpd_analysis.R
```
Inputs: `data/20260210_wash_survey_hh_container_level_PROCESSED.xlsx` (`container` sheet)  
Outputs: `output/container_lpd_artifact_filtered_*.csv`

**Check specific indicator:**
```r
# Read processed household data
wash_data <- readRDS("output/wash_survey_hh_level.rds")

# Quick look at field values
table(wash_data$field_name, useNA = "ifany")
```

**Generate plots only** (after data is processed):
```r
# Plots are generated inline during indicator processing
# To regenerate, run the full script
```

**Excel outputs location:**
```
output/wash_survey_water_indicators.xlsx
output/wash_survey_sanitation_indicators.xlsx
output/wash_survey_hygiene_indicators.xlsx
output/wash_survey_priorities_indicators.xlsx
output/wash_survey_disaggregation_indicators.xlsx
```

**Plot outputs location:**
```
output/plots/water_indicator_*.png
output/plots/sanitation_indicator_*.png
output/plots/hygiene_indicator_*.png
output/plots/priorities_indicator_*.png
output/plots/disaggregation_indicator_*.png
```
