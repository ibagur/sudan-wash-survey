# Sudan WASH Survey Analysis

Analysis of WASH (Water, Sanitation, and Hygiene) survey data from IDP camps in Tawila region, North Darfur, Sudan.

## Project Overview

**Assessment Location:** Tawila, North Darfur, Sudan
**Target Population:** IDP Camps A, B, C, D
**Total Population:** 95,696 individuals
**Survey Design:** Stratified systematic cluster sampling
**Sample Size:** 652 households across 35 clusters
**Expected Precision:** ±5.4% overall, ±9-14% per camp (95% CI)

## Data Collection

**Survey Platform:** KoboToolbox
**Data File:** `data/Kobo version_*.xlsx`
**Reference Documents:** `reference/` directory

## Kobo Data Processing

### Quick Start

```r
source("wash_survey_analysis_v3.R")
```

This downloads the latest data from KoboToolbox using the Kobo Export API and creates household-level analysis-ready files.

### Current Approach (v3)

Uses the **Kobo Export API** (`/api/v2/assets/{id}/exports/`) with the following configuration:
- `type = "xls"` - Excel export format
- `lang = "English (en)"` - English labels for values
- `hierarchy_in_labels = FALSE` - Flat column structure
- `multiple_select = "both"` - Creates summary + boolean columns automatically
- `fields_from_all_versions = FALSE` - Latest version only

**Benefits:**
- ✅ Automatic multiple_select processing (no manual code needed)
- ✅ English labels in values (not XML codes)
- ✅ Simplified codebase (~80 lines vs ~264 lines)
- ✅ Uses official Kobo API (more reliable than direct httr calls)

### Outputs

**Household-Level Dataset** (`output/wash_survey_hh_level.xlsx`)
- **371 rows** - One row per household
- **255 columns** - All questions + boolean indicators for multiple_select
- Use for: Demographics, overall WASH indicators, camp comparisons

**Note:** Container repeat groups are NOT expanded in v3. Container-level analysis will be implemented separately.

### Multiple_Select Questions

The Kobo Export API automatically creates boolean columns for each multiple-choice question:
- Values are `0` or `1` for each choice
- Column names use full English question text (made safe with `janitor::make_clean_names()`)

Example filtering:
```r
# Find households reporting water shortage issues
wash_data %>%
  filter(if_yes_follow_with_the_list_waterpoints_are_too_far == "1")
```

### Configuration

Edit `config.yaml`:
```yaml
kobo:
  url: "kobo.unhcr.org"
  user: "your_username"
  password: "your_password"
  asset_id: "your_asset_id"
```

## Project Structure

```
sudan-wash-survey/
├── CLAUDE.md                          # Detailed guidance for AI-assisted analysis
├── README.md                          # This file
├── wash_survey_analysis_v3.R          # Main Kobo data processing script (Export API)
├── wash_survey_analysis_v2.R          # Legacy script (direct /data.json approach)
├── config.yaml                        # Kobo API credentials
├── data/                              # Survey data (not tracked in git)
│   └── Kobo version_*.xlsx            # Survey definition (XLSForm)
├── reference/                         # Reference documentation
│   ├── SDN_Tawila_Survey_ToR_*.pdf
│   ├── Tawila_Sampling_Analysis.md
│   └── kobo_api_v2.txt
├── output/                            # Processed datasets (not tracked)
│   ├── wash_survey_hh_level.xlsx      # Household-level data
│   └── *.rds                          # R binary format
└── plots/                             # Visualizations (not tracked)
```

## Git Workflow

### Branching Strategy

- **`main`** - Stable releases only. Merge here after completing major analysis phases.
- **`development`** - Active development branch. All work happens here.

### Current Branch

You are currently on: **`development`**

### Workflow

1. **Daily work:** Commit regularly to `development`
   ```bash
   git add <files>
   git commit -m "Descriptive message"
   ```

2. **After completing a phase:** Merge to `main`
   ```bash
   git checkout main
   git merge development
   git tag -a v1.0 -m "Phase 1: Data cleaning and validation"
   git checkout development
   ```

3. **Version tags on main:**
   - v1.0 - Data cleaning and validation
   - v2.0 - Descriptive analysis
   - v3.0 - Camp-level analysis
   - v4.0 - Final reporting

## Analysis Phases

### Phase 1: Data Cleaning and Validation
- [ ] Import KoboToolbox data
- [ ] Verify sample sizes match design (652 HH total)
- [ ] Check cluster sizes (13-21 HH range)
- [ ] Handle missing data
- [ ] Create survey design object with DEFF=2.0

### Phase 2: Descriptive Analysis
- [ ] Overall Tawila-wide estimates
- [ ] Camp-level estimates with confidence intervals
- [ ] Between-camp comparisons
- [ ] Sphere Standards assessment

### Phase 3: Thematic Analysis
- [ ] Water access and quality indicators
- [ ] Sanitation facilities and practices
- [ ] Hygiene knowledge and practices
- [ ] Subgroup analysis (Tawila-wide only)

### Phase 4: Reporting and Visualization
- [ ] Publication-quality tables with CI
- [ ] Maps and plots with confidence bands
- [ ] Executive summary
- [ ] Technical annex

## Key Statistical Considerations

⚠️ **Critical:** All analysis must account for cluster sampling design (DEFF=2.0)

- Use `{survey}` and `{srvyr}` packages for proper variance estimation
- Always report confidence intervals alongside point estimates
- Subgroup analysis ONLY at Tawila-wide level (never by individual camp)
- Detectable differences between camps: ≥20 percentage points

See `CLAUDE.md` for detailed statistical guidance.

## Required R Packages

```r
# Core analysis
library(tidyverse)
library(readxl)
library(here)

# Survey analysis
library(survey)
library(srvyr)

# Reporting
library(gt)
library(scales)
library(patchwork)
```

## Contact

Project Lead: [Your Name]
Organization: UNHCR
Date: February 2026
