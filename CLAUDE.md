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

**Raw survey data** (KoboToolbox export format):
- Excel file: `data/Kobo version_*.xlsx`
- One row per household
- Camp identifier variable
- Cluster identifier variable
- WASH indicators: water access, quantity, quality, sanitation, hygiene

**Reference materials**:
- `reference/SDN_Tawila_Survey_ToR_20260120.docx.pdf` - Terms of Reference
- `reference/Tawila_Sampling_Analysis.md` - Detailed sampling methodology and precision analysis

## Common Packages

```r
# Core tidyverse
library(tidyverse)     # Data manipulation and visualization
library(readxl)        # Excel file import

# Survey analysis
library(survey)        # Complex survey design analysis
library(srvyr)         # Tidyverse-compatible survey functions

# Spatial/camp analysis
library(sf)            # Spatial data handling (if GPS coordinates collected)

# Reporting
library(scales)        # Format percentages and numbers
library(gt)            # Publication-quality tables
library(patchwork)     # Combine ggplot2 plots
```

## Shared Resources

This project is part of a larger collection of UNHCR Information Management tools. Shared utility functions are available in:

- `../_common/functions.R` - Common functions used across multiple projects
  - `make_shelter_table()` - Pivot and summarize categorical data
  - `make_time_displacement_table()` - Summarize temporal patterns
  - `make_reasons_table()` - Process multi-select reason questions
  - `make_places_table()` - Aggregate location data with percentages

Source these functions when needed rather than duplicating code.

## Script Structure Standards

Follow this structure for analysis scripts:

1. **Header**: Purpose, author, date
2. **Libraries**: All packages loaded at top
3. **Configuration**: File paths using `here::here()`, global parameters
4. **Data Import**: Read and validate survey data
5. **Survey Design**: Create survey design object with proper weighting
6. **Cleaning**: Handle missing data, recode variables
7. **Analysis**:
   - Overall Tawila-wide estimates (report MoE)
   - Camp-level estimates (report MoE)
   - Between-camp comparisons (test significance)
8. **Visualization**: Clear plots with confidence intervals
9. **Export**: Results tables with precision metrics

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

## Project Context

This project is part of humanitarian information management work for UNHCR Mozambique operations, though the specific assessment is for Sudan. Related projects in the parent directory include:
- Mozambique cholera response monitoring
- HPM (Humanitarian Performance Monitoring)
- Various 5W (Who, What, Where, When, for Whom) consolidation tools
- Emergency response assessments

Code style and patterns should align with the organizational standards established across these projects.
