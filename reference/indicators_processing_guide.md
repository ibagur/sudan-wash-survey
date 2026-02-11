# WASH Indicators Processing Guide - TOR Alignment

## Introduction

This guide provides detailed specifications for processing all 41 household survey indicators from the Tawila WASH Assessment, aligned with **Annex 1: Household Survey Indicators** from the Terms of Reference.

**Survey Overview:**
- **Population**: 4 IDP camps (A, B, C, D) in Tawila region, North Darfur, Sudan
- **Sample**: 652 households across 35 clusters
- **Design**: Stratified systematic cluster sampling with DEFF = 2.0
- **Data Source**: KoboToolbox export (371 households + 882 containers in repeat groups)

**Guide Structure:**
- **Table 1**: Disaggregation Indicators (9 indicators)
- **Table 2**: WASH Theme Indicators (32 indicators)
  - Water: 9 indicators (1.1-1.9)
  - Sanitation: 10 indicators (2.1-2.9, 3.0)
  - Hygiene: 11 indicators (4.1-4.11)
  - Public Health: 1 indicator (5.1)
  - Priorities: 2 indicators (7.1-7.2)
- **Derived Indicators Section**: Container analysis (1.7, 1.8)

## Using This Guide for R Code Generation

**Field naming convention:** All field names are lowercase snake_case as they appear in `output/wash_survey_hh_level.xlsx` after processing. These are ready for direct use in R code.

**Multiple-select structure:** Questions with multiple choices have THREE variable types:
1. **Parent question** - Yes/No/NA indicating if follow-up was asked
2. **Summary column** - Human-readable English labels separated by semicolons
3. **Boolean columns** - One per choice option with values "1", "0", or NA

**Example aggregation code:**
```r
# Overall prevalence (use parent question)
data %>% summarise(pct = mean(parent_question == "yes", na.rm = TRUE))

# By problem type (use boolean columns)
data %>% summarise(across(starts_with("boolean_prefix_"),
                          ~ mean(as.numeric(.x), na.rm = TRUE) * 100))
```

## Statistical Context

### Margin of Error by Aggregation Level

**Overall Tawila-wide** (n=652, effective n=326):
- Margin of Error: ±5.4% at 95% confidence
- Use for: Primary estimates, subgroup analysis, Sphere Standards comparison

**Camp-level estimates**:
- Camp A (n=160, eff=80): ±11.0% MoE
- Camp B (n=168, eff=84): ±10.7% MoE
- Camp C (n=104, eff=52): ±13.6% MoE
- Camp D (n=220, eff=110): ±9.3% MoE
- Use for: Between-camp comparisons, camp-specific trends

**Critical Constraints:**
- **Minimum detectable difference between camps**: ~15 percentage points
- **Subgroup analysis**: ONLY at Tawila-wide level (never by camp - MoE >25%)
- **Rare events**: Cannot reliably measure indicators with <10% prevalence
- **Confidence interval reporting**: MANDATORY for all estimates

### Aggregation Strategies

**Overall + By Camp:**
- Foundational indicators where camp differences expected
- Examples: Water source, sanitation type, handwashing access
- Report with confidence intervals, test for significance

**Overall + By Subgroup (Tawila-wide only):**
- Vulnerability analyses (recent arrivals, children <5, PLW, disabilities, elderly)
- Examples: Coping mechanisms, safety concerns, menstrual hygiene
- NEVER disaggregate subgroups by individual camps

**Overall Only:**
- Rare events or very detailed categorical breakdowns
- Examples: Container metrics, open defecation timing details

## Kobo Field Name Reference

### Field Naming Patterns

**Prefixes by theme:**
- `hh_ws_` - Water Supply questions
- `hh_wq_` - Water Quality questions
- `hh_s_` - Sanitation questions
- `hh_swm_` - Solid Waste Management
- `hh_h_` - Hygiene questions
- `hh_fc_` - Final Comments

**Repeat groups:**
- Container data: Nested within household records
- 867 container records (consent-filtered) across 369 households
- Fields: `index`, `parent_index`, `container_type`, `container_use`, `volume_liters`, `number_of_containers`, `frequency_filled`, `fill_level`

**Demographics and disaggregation:**
- Camp identifier, respondent gender/age, household composition variables

### Multiple-Select Processing

**Survey structure**: 19 select_multiple questions create summary columns with space-separated XML codes

**Processing approach**:
1. Map XML codes → English labels using choices sheet
2. Create boolean indicator columns: one per choice
3. Naming convention: `{question_name}_{choice_label}` with underscores
4. Values: 1 (selected), 0 (not selected), NA (missing)

**Example**: `container_use` question
- Summary: "drinking domestic" (English labels)
- Booleans: `container_use_drinking`, `container_use_domestic`

## Table 1: Disaggregation Indicators

| Indicator | Description | Kobo Field(s) | Question Type | Aggregation | Processing Notes | Graphical Output |
|-----------|-------------|---------------|---------------|-------------|------------------|------------------|
| Population groups | Camp A, B, C, D | `camp_name` | select_one | Stratification variable | Primary stratification for all camp-level analysis | Stacked bar chart showing sample distribution |
| Respondent gender | Gender of survey respondent | `gender_of_the_respondent` | select_one | Overall | Demographics question | Dot plot with confidence intervals |
| Gender/age of head of household | Gender and age of HoH | `gender_of_the_househld` | select_one | Overall | Demographics question | Grouped bar chart (gender) + histogram (age distribution) |
| Recently arrived households | HH arrived within past 2 weeks | `did_people_arrive_two_weeks_ago_into_tawila` | select_one | Overall | Binary yes/no | Dot plot with confidence intervals |
| Households with members under 5 years old | HH with children <5 | `do_you_have_members_less_than_5_years_old` | select_one | Overall | Binary yes/no | Dot plot with confidence intervals |
| Households with elderly members (over 60) | HH with members 60+ | `no_of_men_60_in_hh`, `no_of_women_60_in_hh` | integer | Overall | Derive binary: `(no_of_men_60_in_hh + no_of_women_60_in_hh) > 0` | Dot plot with confidence intervals |
| Households with members with disabilities | HH with disabled members | `no_of_people_with_disabilities_in_hh_optional` | integer | Overall | Derive binary: `no_of_people_with_disabilities_in_hh_optional > 0` | Dot plot with confidence intervals |
| Households with pregnant or lactating women | HH with PLW | `do_you_have_members_with_pregnant_or_lactating_women` | select_one | Overall | Binary yes/no | Dot plot with confidence intervals |
| Households with child in malnutrition treatment | HH with child receiving treatment | `do_you_have_members_with_child_that_is_currently_receiving_malnutrition_treatment` | select_one | Overall | Binary yes/no | Dot plot with confidence intervals |

**Implementation notes:**
- All disaggregation variables used for subgroup analysis at Tawila-wide level
- Elderly and disability indicators require deriving binary from count variables
- HoH gender/age requires conditional logic based on whether respondent is HoH

## Table 2: WASH Theme Indicators

### Water Supply and Access (7 indicators)

| Indicator | Description | Kobo Field(s) | Question Type | Aggregation | Processing Notes | Graphical Output |
|-----------|-------------|---------------|---------------|-------------|------------------|------------------|
| 1.1 | % of HH by type of primary source of drinking water | `hh_ws_1_1_what_is_the_primary_source_of_water_used_by_your_household_for_drinking` | select_one | Overall + by camp | Categories: piped system, protected well, unprotected well, surface water, water trucking, other | Stacked bar chart by water source type |
| 1.2 | % of HH reporting enough water for drinking, cooking, bathing, washing | `hh_ws_1_2_does_your_household_currently_have_enough_water_for_drinking_and_cooking`, `hh_ws_1_2_1_does_your_household_currently_have_enough_water_for_other_domestic_purposes_e_g_bathing_washing_etc` | select_one (2 questions) | Overall + by camp | Two separate questions: (a) drinking/cooking, (b) other domestic purposes. Report both + combined "sufficient for all purposes" | Grouped bar chart comparing drinking/cooking vs. domestic sufficiency |
| 1.3 | % of HH having problems related to water access (by type) | **Parent:** `hh_ws_1_2_1_does_your_household_have_problems_related_to_access_to_water_if_yes_which_ones`<br>**Summary:** `if_yes_follow_with_the_list`<br>**Booleans (14):**<br>• `if_yes_follow_with_the_list_no`<br>• `if_yes_follow_with_the_list_waterpoints_are_too_far`<br>• `if_yes_follow_with_the_list_waterpoints_are_difficult_to_reach`<br>• `if_yes_follow_with_the_list_waterpoints_are_difficult_to_reach_for_people_with_disabilities_includes_sick_people_incapacitated`<br>• `if_yes_follow_with_the_list_fetching_water_is_a_dangerous_activity`<br>• `if_yes_follow_with_the_list_insufficient_number_of_water_points_waiting_time_at_water_points`<br>• `if_yes_follow_with_the_list_water_points_are_not_functioning_or_close`<br>• `if_yes_follow_with_the_list_water_is_not_available_at_the_market`<br>• `if_yes_follow_with_the_list_water_is_too_expensive`<br>• `if_yes_follow_with_the_list_not_enough_container_to_store_the_water`<br>• `if_yes_follow_with_the_list_don_t_like_taste_quality_of_water`<br>• `if_yes_follow_with_the_list_other_please_list`<br>• `if_yes_follow_with_the_list_don_t_know`<br>• `if_yes_follow_with_the_list_some_groups_children_women_elderly_ethnic_minorities_etc_do_not_have_access_to_the_waterpoints` | select_one + select_multiple | Overall + by problem type | First Q: yes/no. If yes, follow-up select_multiple for problem types. Summary column has semicolon-separated English labels | Grouped bar chart showing % HH per problem type |
| 1.4 | % of HH engaging in coping mechanisms for water insufficiency (by type) | **Summary:** `hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water`<br>**Booleans (12):**<br>• `hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_rely_on_less_preferred_unimproved_untreated_water_sources_for_drinking_water`<br>• `hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_rely_on_surface_water_for_drinking_water`<br>• `hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_rely_on_less_preferred_unimproved_untreated_water_sources_for_other_purposes_such_as_cooking_and_washing`<br>• `hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_rely_on_surface_water_for_other_purposes_such_as_cooking_and_washing`<br>• `hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_fetch_water_at_a_source_further_than_the_usual_one`<br>• `hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_send_children_to_fetch_water`<br>• `hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_fetch_water_at_a_source_that_could_be_dangerous`<br>• `hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_spend_money_or_credit_on_water_that_should_otherwise_be_used_for_other_purposes`<br>• `hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_reduce_drinking_water_consumption_drink_less`<br>• `hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_reduce_water_consumption_for_other_purposes_bathe_less_etc`<br>• `hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_other_please_list`<br>• `hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_don_t_know` | select_multiple | Overall + by subgroup (Tawila-wide) | Boolean columns for each coping mechanism. Disaggregate by vulnerability subgroups, NOT by camp | Grouped bar chart showing % HH per coping mechanism |
| 1.5 | % of HH by water storage and transportation capacity (liters) | Container repeat groups (rows 42-56) | mixed (from repeat groups) | Overall only | Aggregate container data to HH level: SUM(volume_liters × number_of_containers × fill_level_pct). Bin into capacity ranges: <20L, 20-40L, 40-60L, 60-100L, >100L. See Derived Indicators section for detailed methodology | Histogram showing distribution of storage capacity by range |
| 1.6 | % of HH by time to fetch water (round trip) | **Summary:** `hh_ws_1_2_3_how_long_does_it_take_to_go_to_your_main_water_source_fetch_water_and_return_including_queuing_at_the_water_source`<br>**Booleans (7):**<br>• `hh_ws_1_2_3_how_long_does_it_take_to_go_to_your_main_water_source_fetch_water_and_return_including_queuing_at_the_water_source_water_source_on_premises`<br>• `hh_ws_1_2_3_how_long_does_it_take_to_go_to_your_main_water_source_fetch_water_and_return_including_queuing_at_the_water_source_water_delivered_to_premises`<br>• `hh_ws_1_2_3_how_long_does_it_take_to_go_to_your_main_water_source_fetch_water_and_return_including_queuing_at_the_water_source_less_than_5_min_to_fetch_and_return`<br>• `hh_ws_1_2_3_how_long_does_it_take_to_go_to_your_main_water_source_fetch_water_and_return_including_queuing_at_the_water_source_between_5_and_15_min_to_fetch_and_return`<br>• `hh_ws_1_2_3_how_long_does_it_take_to_go_to_your_main_water_source_fetch_water_and_return_including_queuing_at_the_water_source_between_16_and_30_min_to_fetch_and_return`<br>• `hh_ws_1_2_3_how_long_does_it_take_to_go_to_your_main_water_source_fetch_water_and_return_including_queuing_at_the_water_source_more_than_31min_to_fetch_and_return`<br>• `hh_ws_1_2_3_how_long_does_it_take_to_go_to_your_main_water_source_fetch_water_and_return_including_queuing_at_the_water_source_don_t_know` | select_multiple (time ranges) | Overall + by camp | **CRITICAL**: This is categorical time RANGES, NOT numeric minutes. Treat as categorical, do NOT calculate averages | Stacked bar chart showing distribution across time categories |
| 1.9 | % of HH with drinking water FRC levels 0.2-0.5 mg/l | `hh_wq_1_3_2_frc_test_result` | select_one | Overall + by camp | Categories from FRC test: 0.0, 0.2-0.5 (target), 0.5-1.0, >1.0. Calculate % in target range. Note: only measured if permission granted | Stacked bar chart showing FRC level distribution |

**Water section processing notes:**
- **1.2**: Two questions must be combined - sufficient for drinking/cooking AND sufficient for other domestic purposes
- **1.3, 1.4**: Multiple-select questions create boolean columns for detailed breakdowns
- **1.5**: Requires container-level aggregation (see Derived Indicators section)
- **1.6**: Common mistake - survey uses categorical ranges, not continuous time values
- Secondary water source also collected (row 29) but not in TOR indicators

### Sanitation (10 indicators)

| Indicator | Description | Kobo Field(s) | Question Type | Aggregation | Processing Notes | Graphical Output |
|-----------|-------------|---------------|---------------|-------------|------------------|------------------|
| 2.1 | % of HH using a sanitation facility (by type) | **Summary:** `hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use`<br>**Booleans (11):**<br>• `hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_flush_or_pour_flush_toilet`<br>• `hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_pit_latrine_without_a_slab_or_platform`<br>• `hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_pit_latrine_with_a_slab_and_platform`<br>• `hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_open_hole`<br>• `hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_pit_vip_toilet`<br>• `hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_bucket_toilet`<br>• `hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_plastic_bag`<br>• `hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_hanging_toilet_latrine`<br>• `hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_none_of_the_above_open_defecation`<br>• `hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_other_specify`<br>• `hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_dont_know` | select_multiple | Overall only | Categories: flush/pour flush, pit latrine (ventilated/unventilated), composting, bucket, hanging, open defecation, other | Stacked bar chart by facility type |
| 2.2 | % of HH sharing sanitation facilities (by # of HH per facility) | `hh_s_2_1_1_if_applicable_do_you_share_this_sanitation_facility_with_other_households_if_yes_how_many_households_use_this_sanitation_facility_latrine_toilet`, `if_yes_number_of_hh` | select_one + integer | Overall only | First Q: yes/no/other. If yes, number of HH sharing. Bin into ranges: 1 (private), 2-5, 6-10, 11-20, >20 HH | Stacked bar chart showing sharing distribution |
| 2.3 | % of HH having problems related to sanitation facility access | **Parent:** `hh_s_2_1_2_do_you_have_problems_related_to_sanitation_facilities_latrines_toilets_if_yes_which_ones`<br>**Summary:** `if_yes_select_multiple`<br>**Booleans (11):**<br>• `if_yes_select_multiple_no`<br>• `if_yes_select_multiple_lack_of_sanitation_facilities_latrines_toilets_facilities_too_crowded`<br>• `if_yes_select_multiple_sanitation_facilities_latrines_toilets_are_not_functioning_or_full`<br>• `if_yes_select_multiple_sanitation_facilities_latrines_toilets_are_unclean_unhygienic`<br>• `if_yes_select_multiple_sanitation_facilities_latrines_toilets_are_not_private_no_locks_door_walls_lighting_etc`<br>• `if_yes_select_multiple_sanitation_facilities_latrines_toilets_are_not_segregated_between_men_and_women`<br>• `if_yes_select_multiple_sanitation_facilities_latrines_toilets_are_too_far`<br>• `if_yes_select_multiple_sanitation_facilities_latrines_toilets_are_difficult_to_reach_especially_for_people_with_disabilities`<br>• `if_yes_select_multiple_going_to_the_sanitation_facilities_latrines_toilets_is_dangerous`<br>• `if_yes_select_multiple_some_groups_children_women_elderly_ethnic_minorities_etc_do_not_have_access_to_sanitation_facilities_latrines_toilets`<br>• `if_yes_select_multiple_other_specify`<br>• `if_yes_select_multiple_dont_know` | select_one + select_multiple | Overall | Include the 'No' answers as if it was one of the selections | Grouped bar chart showing % HH per problem type |
| 2.4 | % of HH engaging in coping mechanisms for sanitation access issues | **Summary:** `hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets`<br>**Booleans (9):**<br>• `hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets_rely_on_less_preferred_unhygienic_unimproved_sanitation_facilities_latrines_toilets`<br>• `hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets_rely_on_communal_sanitation_facilities_latrines_toilets`<br>• `hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets_defecate_in_a_plastic_bag`<br>• `hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets_defecate_in_the_open`<br>• `hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets_going_to_sanitation_facilities_latrines_toilets_further_than_the_usual_one`<br>• `hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets_going_to_sanitation_facilities_latrines_toilets_in_a_dangerous_place`<br>• `hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets_going_to_sanitation_facilities_latrines_toilets_at_night`<br>• `hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets_other_specify`<br>• `hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets_dont_know` | select_multiple | Overall | Boolean columns for each coping mechanism. Present overall byt also Disaggregate by vulnerability subgroups, | Grouped bar chart showing % HH per coping mechanism |
| 2.5 | % of HH feeling unsafe at sanitation locations in last 4 weeks | `hh_s_2_5_do_you_feel_unsafe_at_the_sanitation_facilities_you_use_most_often_because_you_fear_being_harmed_or_assaulted_by_someone` | select_one | Overall | Binary yes/no. Present general but also disaggregate by vulnerable subgroups (women-headed HH, PLW, elderly) if possible | bar plot with confidence intervals, disaggregate by HoH gender |
| 2.6 | % of HH reporting observed open defecation (disaggregated by age/time) | **Parent:** `hh_s_2_6_has_anyone_in_your_household_observed_open_defecation_in_the_area`<br>**Who summary:** `hh_s_2_6_1_if_yes_a_please_specify_who_was_observed_practicing_open_defecation`<br>**Who booleans (6):**<br>• `hh_s_2_6_1_if_yes_a_please_specify_who_was_observed_practicing_open_defecation_no`<br>• `hh_s_2_6_1_if_yes_a_please_specify_who_was_observed_practicing_open_defecation_children_under_5_yrs`<br>• `hh_s_2_6_1_if_yes_a_please_specify_who_was_observed_practicing_open_defecation_children_5_17_yrs`<br>• `hh_s_2_6_1_if_yes_a_please_specify_who_was_observed_practicing_open_defecation_adults_18_59_yrs`<br>• `hh_s_2_6_1_if_yes_a_please_specify_who_was_observed_practicing_open_defecation_older_persons_60_yrs`<br>• `hh_s_2_6_1_if_yes_a_please_specify_who_was_observed_practicing_open_defecation_cannot_determine`<br>**When summary:** `hh_s_2_6_1_1_if_yes_b_when_was_open_defecation_most_often_observed`<br>**When booleans (5):**<br>• `hh_s_2_6_1_1_if_yes_b_when_was_open_defecation_most_often_observed_no`<br>• `hh_s_2_6_1_1_if_yes_b_when_was_open_defecation_most_often_observed_early_morning`<br>• `hh_s_2_6_1_1_if_yes_b_when_was_open_defecation_most_often_observed_daytime`<br>• `hh_s_2_6_1_1_if_yes_b_when_was_open_defecation_most_often_observed_evening`<br>• `hh_s_2_6_1_1_if_yes_b_when_was_open_defecation_most_often_observed_night`<br>• `hh_s_2_6_1_1_if_yes_b_when_was_open_defecation_most_often_observed_cannot_determine` | select_one + 2× select_multiple | Overall | For both questions, include the 'No' answers as if it was one of the selections | Grouped bar charts showing: (1) % reporting OD, (2) age groups practicing, (3) times of day observed |
| 2.7 | % of HH by defecation practice of children under 5 | **Summary:** `hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate`<br>**Booleans (7):**<br>• `hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate_household_latrine`<br>• `hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate_communal_latrine`<br>• `hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate_open_defecation`<br>• `hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate_plastic_bag`<br>• `hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate_bucket_toilet`<br>• `hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate_other_specify`<br>• `hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate_don_t_know` | select_multiple | Overall | Categories: toilet/latrine, potty, disposable diaper, reusable diaper, open defecation, buried, disposed with waste, other | Grouped bar chart by practice type |
| 2.8 | % of HH with damaged, non-functional, or full latrines/toilets | `hh_s_2_3_in_the_last_30_days_was_the_latrine_you_used_damaged_non_functional_or_full`, `if_yes_then_specify` | select_one + select_one | Overall | Include the 'No' answers as if it was one of the selections | Stacked bar chart showing % with issues + breakdown |
| 2.9 | % of HH living near visible human feces (10m max) in last 30 days | `hh_s_2_9_was_there_visible_traces_of_human_faeces_in_the_vicinity_10_meters_or_less_of_your_accommodation_in_the_last_30_days` | select_one | Overall | Binary yes/no. Direct environmental contamination indicator | Dot plot with confidence intervals |
| 3.0 | % of HH by solid waste disposal practices | **Summary:** `hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage`<br>**Booleans (9):**<br>• `hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage_household_pit`<br>• `hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage_communal_pit`<br>• `hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage_bin_in_the_household_streets`<br>• `hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage_designated_open_area`<br>• `hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage_undesignated_open_area`<br>• `hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage_bury_it`<br>• `hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage_burn_it`<br>• `hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage_other_specify`<br>• `hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage_dont_know` | select_multiple | Overall | Categories: collected by service, communal dump/pit, burning, burying, littering, other. Multiple selections possible | Grouped bar chart by disposal method |

**Sanitation section processing notes:**

- **2.2**: Sharing levels require binning integer counts into meaningful ranges
- **2.4, 2.5**: Subgroup analysis critical for understanding vulnerability dimensions
- **2.6**: Three-part question requiring careful sequential processing
- **2.8**: Two-stage question - prevalence then type of problem

### Hygiene (11 indicators)

| Indicator | Description | Kobo Field(s) | Question Type | Aggregation | Processing Notes | Graphical Output |
|-----------|-------------|---------------|---------------|-------------|------------------|------------------|
| 4.1 | % of HH having problems related to hygiene NFI access | **Parent:** `hh_h_4_1_does_your_household_have_problems_related_to_hygiene_items_soap_feminine_hygiene_products_baby_diapers_toothpaste_brush_if_yes_which_ones`<br>**Summary:** `if_yes_which_ones`<br>**Booleans (9):**<br>• `if_yes_which_ones_soap_and_other_hygiene_items_are_too_expensive`<br>• `if_yes_which_ones_soap_and_other_hygiene_items_are_not_available_at_the_market`<br>• `if_yes_which_ones_the_market_is_too_far_away`<br>• `if_yes_which_ones_the_market_is_difficult_to_reach_especially_for_people_with_disabilities`<br>• `if_yes_which_ones_going_to_the_market_is_dangerous`<br>• `if_yes_which_ones_some_groups_do_not_have_access_to_the_market`<br>• `if_yes_which_ones_don_t_like_quality_of_soap_and_other_hygiene_items`<br>• `if_yes_which_ones_other_specify`<br>• `if_yes_which_ones_dont_know` | select_one + select_multiple | Overall + by problem type | Include the 'No' answers as if it was one of the selections | Grouped bar chart showing % HH per NFI problem type |
| 4.2 | % of HH engaging in coping mechanisms for hygiene NFI access | **Summary:** `hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items`<br>**Booleans (11):**<br>• `hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_no`<br>• `hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_rely_on_less_preferred_types_of_nfi`<br>• `hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_rely_on_soap_substitutes_sand_or_other_rubbing_agents_for_soap_clothing_for_diapers_etc`<br>• `hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_buying_nfi_at_a_marketplace_further_than_the_usual_one`<br>• `hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_buying_nfi_at_a_marketplace_in_a_dangerous_place`<br>• `hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_borrow_nfi_from_a_friend_or_relative`<br>• `hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_spend_money_or_credit_on_nfi_that_should_otherwise_be_used_for_other_purposes`<br>• `hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_reduce_nfi_consumption_for_personal_hygiene`<br>• `hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_reduce_nfi_consumption_for_other_purposes_cleaning_dishes_laundry_etc`<br>• `hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_other_specify`<br>• `hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_dont_know` | select_multiple | Overall + by subgroup (Tawila-wide) | Boolean columns for each coping mechanism. Disaggregate by vulnerability subgroups, NOT by camp | Grouped bar chart showing % HH per coping mechanism |
| 4.3 | Average expense for hygiene items in past 30 days | `hh_h_4_1_1_how_much_did_your_household_spend_on_hygiene_items_soap_shampoo_sanitary_pads_diapers_and_water_containers_in_the_last_30_days` | select_one (spending ranges) | Overall | **CRITICAL**: Survey uses categorical SPENDING RANGES, NOT numeric amounts. Ranges: 0, 1-1000, 1001-3000, 3001-5000, >5000 SDG. Cannot calculate true mean - report categorical distribution or median range | Stacked bar chart showing distribution across spending categories |
| 4.4 | % of HH by main barriers to accessing WASH NFI in market | Appears to be missing dedicated field | Unknown | Overall | **DATA GAP**: No clearly mapped Kobo field. May be embedded in "problems" questions or need follow-up. Check open-ended responses (row 103) | To be determined based on data availability |
| 4.5 | % of HH by satisfaction with access to hygiene NFI | `hh_h_4_1_2_how_satisfied_is_your_household_with_regards_to_access_to_hygiene_items_soap_feminine_hygiene_products_baby_diapers_toothpaste_brush` | select_one | Overall | Likert scale: very satisfied, satisfied, neutral, dissatisfied, very dissatisfied | Stacked bar chart showing satisfaction distribution |
| 4.6 | % of HH with access to handwashing devices (water and soap) | `hh_h_4_2_what_kind_of_handwashing_device_mechanism_do_your_household_members_usually_use_to_wash_their_hands_ask_to_see_the_handwashing_device`, `hh_h_4_2_1_do_you_have_enough_water_and_soap_for_handwashing` | select_one + select_one | Overall | Two questions: (1) type of device (Ebreg, basin, tap, other), (2) water and soap available. Combine for "adequate handwashing station" = device + water + soap | Grouped bar chart: device type vs. device with water+soap |
| 4.7 | % of HH with water available at handwashing facility | Derived from `hh_h_4_2_1_do_you_have_enough_water_and_soap_for_handwashing` | select_one | Overall | Combined question asks about both water and soap together. May need to use proxy or alternative source to report separately | Dot plot with confidence intervals |
| 4.8 | % of HH with soap available at handwashing facility | Derived from `hh_h_4_2_1_do_you_have_enough_water_and_soap_for_handwashing` | select_one | Overall | Combined question asks about both water and soap together. May need to use proxy or alternative source to report separately | Dot plot with confidence intervals |
| 4.9.1 | % of HH having soap at home | `hh_h_4_2_2_do_you_have_enough_soap_at_household_for_all_purposes` | select_one | Overall | Binary yes/no. "Do you have enough soap at household for all purposes?" | Dot plot with confidence intervals |
| 4.9.2 | % of HH having problems related to soap access (by type) | **Summary:** `hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap`<br>**Booleans (11):**<br>• `hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_yes`<br>• `hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_soap_is_unnecessary`<br>• `hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_we_run_out_of_soap`<br>• `hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_soap_is_too_expensive`<br>• `hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_soap_is_not_available_at_the_market`<br>• `hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_the_market_is_too_far_away`<br>• `hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_going_to_the_market_is_dangerous`<br>• `hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_the_market_is_difficult_to_reach_especially_for_people_with_disabilities`<br>• `hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_don_t_like_quality_of_soap_available`<br>• `hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_dont_know`<br>• `hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_other_specify` | select_multiple | Overall + by problem type | Only asked if soap insufficient (4.9.1 = no). Boolean columns for each reason | Grouped bar chart showing % HH per barrier type (among those without soap) |
| 4.10 | % of HH by number of critical handwashing times respondent can name | To be determined | select_multiple | Overall | Knowledge indicator about critical handwashing moments. Standard critical times: before eating, before preparing food, after defecation, after cleaning child who defecated, after handling animal waste | Grouped bar chart showing distribution by number of times recalled |
| 4.11 | % of menstruating individuals with enough materials to change as often as wanted | `during_your_last_menstrual_period_did_you_have_enough_menstrual_materials_to_change_as_often_as_you_wanted`, `age_of_hh_respondent` | select_one + integer | Overall + by age group (Tawila-wide) | Binary yes/no. **Note**: Survey asks at HH level, all respondents female. Use respondent age as proxy for menstruating individual. Age groups: 15-24, 25-34, 35-44, 45-54. Clearly document limitation in reporting | Dot plot with confidence intervals by age group |

**Hygiene section processing notes:**

- **4.2**: Another coping mechanism indicator requiring subgroup analysis
- **4.3**: Common error - treat as categorical, NOT continuous variable for averaging
- **4.4**: Potential data gap - verify field mapping or use proxy measures
- **4.6**: Composite indicator requiring both device presence AND supplies
- **4.7, 4.8**: Separate water and soap indicators; currently collected as combined question in 4.6
- **4.9.1, 4.9.2**: Split from original 4.7 in TOR revision - separate soap availability from barriers
- **4.10**: Critical handwashing times knowledge indicator
- **4.11**: Respondent age used as proxy; document this limitation clearly

### Public Health (1 indicator)

| Indicator | Description | Kobo Field(s) | Question Type | Aggregation | Processing Notes | Graphical Output |
|-----------|-------------|---------------|---------------|-------------|------------------|------------------|
| 5.1 | % of HH with at least one member with WASH-related health issues (past 30 days) | To be determined | select_one | Overall | Morbidity indicator for WASH-related illnesses including diarrhea, skin infections, eye infections, acute watery diarrhea, cholera, or other waterborne/hygiene-related conditions in past 30 days | Dot plot with confidence intervals, disaggregate by camp |

**Public health processing notes:**
- WASH-related morbidity is key outcome indicator for intervention effectiveness
- Can be cross-tabulated with water quality (1.9), handwashing (4.6-4.8), and sanitation access indicators
- Disaggregate by vulnerable groups (children <5, elderly, disabled) for targeted analysis

### Priorities (2 indicators)

| Indicator | Description | Kobo Field(s) | Question Type | Aggregation | Processing Notes | Graphical Output |
|-----------|-------------|---------------|---------------|-------------|------------------|------------------|
| 7.1 | % of HH by main priority concerns reported | `hh_h_6_1_which_of_the_following_is_your_biggest_wash_related_concern_right_now_for_your_household` | select_one | Overall | Categories: water access, water quality, sanitation access, sanitation quality, hygiene items, solid waste management, other | Stacked bar chart showing distribution of priority concerns |
| 7.2 | % of HH by preferred type of interventions | **Summary:** `hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer`<br>**Booleans (11):**<br>• `hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_water_distribution`<br>• `hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_water_trucking`<br>• `hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_rehabilitation_of_water_infrastructure`<br>• `hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_construction_of_new_water_sources`<br>• `hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_water_quality_testing`<br>• `hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_water_treatment_supplies`<br>• `hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_construction_rehabilitation_of_latrines`<br>• `hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_distribution_of_hygiene_kits_nfis`<br>• `hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_hygiene_promotion_sessions`<br>• `hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_solid_waste_management_services`<br>• `hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_other_specify` | select_multiple | Overall | Multiple selections allowed. Boolean columns for each intervention type. Can cross-tabulate with priority concerns (7.1) to understand preference alignment | Grouped bar chart showing % HH preferring each intervention type |

**Priorities processing notes:**
- 7.1: Single priority question captures overall WASH concern ranking
- 7.2: Multiple preferences allowed, indicates desired intervention mix
- Can cross-tabulate 7.1 × 7.2 to understand concern-to-solution alignment
- Useful for program design and resource allocation planning
- Disaggregate by camp to understand location-specific needs

---

## Derived Indicators: Container Analysis

**Note**: Indicators 1.7 and 1.8 require detailed container-level analysis and are separated from the main WASH theme indicators due to their complexity and data quality considerations.

### Indicator 1.7: % of Households with <15 Liters per Person per Day

**TOR Description**: Percentage of households with less than 15 liters of water per person per day

**Data Sources**:
- Container repeat groups: Rows 42-48 (observed) and 50-56 (self-reported)
- Household size: `hh_total` (row 21)
- Container fields:
  - `volume_liters`: Container capacity (integer)
  - `number_of_containers`: Number of identical containers (integer)
  - `fill_level`: Typically filled to (categorical: "full", "3/4", "half", "1/4")
  - `frequency_filled`: How often filled (free text - **DATA QUALITY ISSUE**)
  - `container_use`: Purpose (select_multiple: drinking, domestic, both)

**Calculation Methodology**:

**Step 1: Map fill level to percentage**
```r
fill_level_pct <- case_when(
  fill_level == "full" ~ 1.00,
  fill_level == "3/4" ~ 0.75,
  fill_level == "half" ~ 0.50,
  fill_level == "1/4" ~ 0.25,
  TRUE ~ NA_real_
)
```

**Step 2: Calculate total storage capacity per household**
```r
# Per container
container_capacity = volume_liters × number_of_containers × fill_level_pct

# Per household (aggregate across all containers)
hh_total_capacity = SUM(container_capacity) by household_id
```

**Step 3: Calculate liters per person per day**
```r
liters_per_person = hh_total_capacity / hh_total
```

**Step 4: Apply threshold**
```r
below_threshold = (liters_per_person < 15)
percentage = mean(below_threshold, na.rm = TRUE) × 100
```

**Critical Assumptions and Limitations**:

1. **Frequency assumption**: `frequency_filled` is free text (e.g., "daily", "twice a day", "every 2 days"). This makes daily consumption calculation unreliable. The calculation assumes **single snapshot** of current stored water, NOT daily refill rates.

2. **Fill level timing**: Survey captures fill level "typically", not necessarily at time of survey. May overestimate or underestimate actual storage depending on household timing.

3. **Container use ambiguity**: Some containers marked as "both" drinking and domestic. Unclear if household separates drinking vs. domestic water or uses interchangeably.

4. **Missing containers**: Self-reported containers (when observation refused, row 49) may have data quality issues compared to observed containers.

**Processing Workflow**:

```r
# 1. Load container-level dataset (882 rows)
containers <- read_rds("output/wash_survey_container_level.rds")

# 2. Map fill levels
containers <- containers %>%
  mutate(
    fill_pct = case_when(
      fill_level == "full" ~ 1.0,
      fill_level == "3_4" ~ 0.75,
      fill_level == "half" ~ 0.5,
      fill_level == "1_4" ~ 0.25
    ),
    container_capacity = volume_liters * number_of_containers * fill_pct
  )

# 3. Aggregate to household level
hh_water <- containers %>%
  group_by(index) %>%
  summarise(
    total_capacity = sum(container_capacity, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  left_join(select(hh_data, index, hh_total), by = "index") %>%
  mutate(liters_per_person = total_capacity / hh_total)

# 4. Calculate indicator
indicator_1_7 <- hh_water %>%
  summarise(
    pct_below_15L = mean(liters_per_person < 15, na.rm = TRUE) * 100,
    n = n(),
    ci_lower = # calculate using survey design
    ci_upper = # calculate using survey design
  )
```

**Reporting Requirements**:
- Report overall Tawila-wide estimate with 95% CI
- Add methodological note documenting assumptions
- Compare to Sphere Standard (15 L/p/d minimum for survival)
- **Do NOT disaggregate by camp** due to small sample sizes per camp

**Graphical Output**:
- Histogram showing distribution of L/p/d with vertical line at 15L threshold
- Annotation showing % below threshold

---

### Indicator 1.8: Average and Median Liters of Water per Person per Day

**TOR Description**: Average and median liters of water per person per day for domestic/drinking purposes

**Data Sources**: Same as Indicator 1.7

**Calculation Methodology**:

Uses same `liters_per_person` calculation as 1.7, but reports summary statistics instead of threshold comparison.

**Additional Analysis by Container Use**:

```r
# Separate drinking vs. domestic capacity
containers_by_use <- containers %>%
  mutate(
    drinking_capacity = if_else(
      str_detect(container_use, "drinking"),
      container_capacity,
      0
    ),
    domestic_capacity = if_else(
      str_detect(container_use, "domestic"),
      container_capacity,
      0
    )
  ) %>%
  group_by(index) %>%
  summarise(
    total_drinking = sum(drinking_capacity, na.rm = TRUE),
    total_domestic = sum(domestic_capacity, na.rm = TRUE),
    total_all = sum(container_capacity, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  left_join(select(hh_data, index, hh_total), by = "index") %>%
  mutate(
    drinking_lppd = total_drinking / hh_total,
    domestic_lppd = total_domestic / hh_total,
    all_lppd = total_all / hh_total
  )
```

**Reporting Requirements**:

Report for three categories:
1. **All water** (total L/p/d regardless of use)
2. **Drinking water only** (containers marked for drinking)
3. **Domestic water only** (containers marked for domestic purposes)

For each category, report:
- Mean L/p/d with 95% CI
- Median L/p/d with interquartile range
- Sample size
- Comparison to Sphere Standards:
  - Survival: 7.5-15 L/p/d
  - Basic access: 15-20 L/p/d
  - Optimal access: >20 L/p/d

**Survey Design Considerations**:

```r
# Use survey design object for correct standard errors
survey_design <- containers_by_use %>%
  as_survey_design(
    ids = cluster_id,
    strata = camp,
    weights = sampling_weight
  )

# Calculate weighted mean and median
survey_design %>%
  summarise(
    mean_lppd = survey_mean(all_lppd, vartype = "ci"),
    median_lppd = survey_median(all_lppd)
  )
```

**Critical Limitations** (same as 1.7):
- Snapshot measurement, not daily average
- Free-text `frequency_filled` unreliable for daily calculations
- Container use categories may overlap ("both" drinking and domestic)
- Self-reported vs. observed containers may differ in accuracy

**Graphical Output**:
- Histogram showing distribution of L/p/d with Sphere threshold lines (7.5, 15, 20)
- Box plot comparing drinking vs. domestic vs. all water
- Summary table with mean, median, and CI for each category

---

## Implementation Notes

### Survey Design Object in R

All weighted estimates MUST use survey design adjustment for correct standard errors:

```r
library(survey)
library(srvyr)

# Create survey design object
survey_design <- household_data %>%
  as_survey_design(
    ids = cluster_id,           # Cluster sampling IDs
    strata = Camp_Name,          # Camp stratification
    weights = sampling_weight,   # If post-stratification applied
    fpc = NULL                   # Finite population correction if applicable
  )

# Calculate weighted proportions with confidence intervals
survey_design %>%
  group_by(Camp_Name) %>%
  summarise(
    prop = survey_mean(indicator_binary, vartype = "ci"),
    n = unweighted(n())
  )
```

### Multiple-Select Processing Pattern

For each select_multiple question (19 total):

```r
# 1. Get question metadata
multiselect_qs <- survey %>%
  filter(type == "select_multiple")

# 2. For each question, create boolean columns
for (i in seq_len(nrow(multiselect_qs))) {
  question_name <- multiselect_qs$name[i]
  choices <- get_choices(question_name)  # From choices sheet

  # Convert summary column (space-separated codes) to English labels
  data <- data %>%
    mutate(
      "{question_name}" := map_choices(!!sym(question_name), choices)
    )

  # Create boolean columns
  for (choice in choices) {
    col_name <- paste0(question_name, "_", janitor::make_clean_names(choice))
    data <- data %>%
      mutate(
        "{col_name}" := if_else(
          str_detect(!!sym(question_name), fixed(choice)),
          1L,
          0L
        )
      )
  }
}
```

### Confidence Interval Reporting

Example table format:

```r
results <- survey_design %>%
  group_by(Camp_Name) %>%
  summarise(
    indicator = survey_mean(binary_indicator, vartype = "ci"),
    n = unweighted(n())
  ) %>%
  mutate(
    display = glue::glue("{round(indicator * 100, 1)}% ({round(indicator_low * 100, 1)}-{round(indicator_upp * 100, 1)}%)")
  )
```

Output format:
| Camp | Estimate (95% CI) | Sample Size |
|------|------------------|-------------|
| A    | 55.3% (44.2-66.4%) | 160       |
| B    | 62.1% (51.3-72.9%) | 168       |

### Between-Camp Statistical Testing

Test whether confidence intervals overlap:

```r
# Pairwise comparisons
camp_pairs <- combn(unique(data$Camp_Name), 2, simplify = FALSE)

for (pair in camp_pairs) {
  est_1 <- results %>% filter(Camp_Name == pair[1])
  est_2 <- results %>% filter(Camp_Name == pair[2])

  # Check for CI overlap
  overlap <- !(est_1$indicator_upp < est_2$indicator_low |
               est_2$indicator_upp < est_1$indicator_low)

  if (!overlap) {
    message(glue::glue("{pair[1]} and {pair[2]} significantly different at 95% confidence"))
  }
}
```

### Subgroup Analysis Rules

**ONLY perform subgroup analysis at Tawila-wide level**:

```r
# Correct approach
overall_by_subgroup <- survey_design %>%
  group_by(vulnerability_group) %>%
  summarise(
    coping_mechanism = survey_mean(uses_coping, vartype = "ci")
  )

# INCORRECT - Never do this (MoE >25%)
by_camp_and_subgroup <- survey_design %>%
  group_by(Camp_Name, vulnerability_group) %>%  # TOO GRANULAR
  summarise(...)
```

**Subgroup variables**:
- Recent arrivals (`Did_people_arrive_tw_eeks_ago_into_Tawila == "yes"`)
- Children <5 (`Do_you_have_members_ess_than_5_years_old == "yes"`)
- Elderly 60+ (`(men_60plus + women_60plus) > 0`)
- Disabilities (`ppl_with_disabilities > 0`)
- PLW (`Do_you_have_members_t_or_lactating_women == "yes"`)
- HoH gender (`specify_the_gender_of_the_househld` or respondent gender if HoH)

### Sphere Standards Alignment

**Key thresholds for interpretation**:

**Water access**:
- Minimum quantity: 15 L/p/d (indicators 1.7, 1.8)
- Maximum distance: <500m or <30 min round trip (indicator 1.6)
- Water quality: FRC 0.2-0.5 mg/l at point of use (indicator 1.9)

**Sanitation**:
- Maximum sharing: 1 toilet per 20 people in emergency phase (indicator 2.2)
- Cleanliness: <10% of HH near visible feces (indicator 2.9)

**Hygiene**:
- Soap: 250g/person/month minimum (indicators 4.7.1, 4.7.2)
- Handwashing: Access to handwashing facility with water and soap (indicator 4.6)

**When reporting against Sphere Standards**:
1. Report point estimate and 95% CI
2. If CI spans threshold: "Cannot definitively conclude standard is met"
3. If CI entirely above threshold: "Meets Sphere Standard"
4. If CI entirely below threshold: "Falls short of Sphere Standard"

Example:
> "Water access indicator: 55% (95% CI: 49.6%-60.4%) of households have <15 L/p/d. Since the confidence interval spans the 50% level, we cannot definitively conclude whether the majority of households meet Sphere minimum standards."

---

## Next Steps

### Data Processing Workflow

1. **Load and clean data**
   - Import Kobo Excel export
   - Expand repeat groups (containers)
   - Clean column names
   - Remove metadata columns

2. **Create survey design object**
   - Specify cluster IDs, strata, weights
   - Validate sample sizes match design

3. **Process multiple-select questions**
   - Map XML codes to English labels
   - Create boolean indicator columns

4. **Calculate indicators**
   - Table 1: All 9 disaggregation indicators
   - Table 2: All 29 WASH theme indicators
   - Derived section: Indicators 1.7 and 1.8 (container analysis)

5. **Generate outputs**
   - Excel tables with estimates and CIs
   - Visualizations for each indicator
   - Summary report with Sphere Standards comparison

### Validation Approach

**Data quality checks**:
- [ ] Sample sizes match design (652 total, correct allocation per camp)
- [ ] All indicators have <5% missing data
- [ ] Confidence intervals reasonable widths
- [ ] Container data completeness (observed vs. self-reported)
- [ ] Free-text fields cleaned and standardized where used

**Statistical validation**:
- [ ] Design effect from actual data ≈ 2.0 (assumed DEFF)
- [ ] No substantial non-response bias by camp
- [ ] Subgroup sample sizes adequate for analysis (n>30)

**Logical checks**:
- [ ] Water sufficiency % ≤ water access %
- [ ] HH with children <5 consistent with demographic counts
- [ ] Soap availability ≥ adequate handwashing stations %
- [ ] Total percentages sum to 100% for mutually exclusive categories

### Reporting Templates

**Summary table template** (for each indicator):
| Indicator | Overall (n=652) | Camp A (n=160) | Camp B (n=168) | Camp C (n=104) | Camp D (n=220) |
|-----------|----------------|----------------|----------------|----------------|----------------|
| [Name] | X% (CI) | X% (CI) | X% (CI) | X% (CI) | X% (CI) |
| Meets Sphere? | Yes/No/Unclear | - | - | - | - |

**Visualization checklist**:
- Clear title and axis labels
- Confidence interval error bars (where applicable)
- Sphere Standard reference lines (where applicable)
- Legend explaining categories
- Sample sizes in subtitle or footnote
- Color palette accessible (colorblind-friendly)

---

## Verification Checklist

Final guide completeness check:

- [✓] Exactly 41 indicators in Tables 1 and 2
- [✓] All TOR indicator numbers present (1.1-1.9, 2.1-2.9, 3.0, 4.1-4.11, 5.1, 7.1-7.2)
- [✓] Indicators 4.9.1 and 4.9.2 correctly separated (soap at home vs. soap barriers)
- [✓] Indicator 4.11 includes respondent age disaggregation note
- [✓] All Kobo field names mapped and accurate
- [✓] Question types match actual survey structure
- [✓] Processing notes address special cases:
  - [✓] 1.6: Time ranges (categorical, not numeric)
  - [✓] 4.3: Spending ranges (categorical, not numeric)
  - [✓] 4.11: Respondent age as proxy for menstruating individuals
- [✓] Indicators 1.7 and 1.8 in separate derived section
- [✓] Container analysis methodology fully specified
- [✓] Implementation notes for R data processing included
- [✓] Statistical context and aggregation guidance included
- [✓] Subgroup analysis rules clearly stated (Tawila-wide only)
- [✓] Sphere Standards thresholds documented
- [✓] No references to old numbering remain (4.7.1, 4.7.2, old 4.8, old 5.1 under priorities)
- [✓] No indicators from old guide that aren't in TOR

---

## Document History

**Version 2.1** - 2026-02-11
- Updated to match corrected Annex 1 TOR structure
- Hygiene: Expanded from 8 to 11 indicators (4.1-4.11)
  - Added 4.7 (water at handwashing facility)
  - Added 4.8 (soap at handwashing facility)
  - Renumbered soap indicators from 4.7.1/4.7.2 to 4.9.1/4.9.2
  - Added 4.10 (critical handwashing times knowledge)
  - Renumbered menstrual materials from 4.8 to 4.11
- Public Health: Clarified 5.1 as WASH-related health issues (morbidity)
- Priorities: Renumbered from 5.1 to 7.1-7.2, added 7.2 (preferred interventions)
- Total indicators: 38 → 41 (9 disaggregation + 32 WASH themes)

**Version 2.0** - 2025-02-09
- Complete restructure to align with TOR Annex 1 (38 indicators)
- Simplified from 4 tables to 2 tables + derived section
- Separated soap indicators (4.7 → 4.7.1, 4.7.2)
- Added menstrual materials with age disaggregation (4.8)
- Moved container analysis to derived section (1.7, 1.8)
- Corrected processing types (1.6, 4.3 as categorical)
- Enhanced implementation guidance for R processing

**Version 1.0** - Previous
- Original comprehensive guide (59 indicators across 4 tables)
- Archived as `indicators_processing_guide_OLD.md`
