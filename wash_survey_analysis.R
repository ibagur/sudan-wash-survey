# Kobo Data Retrieval - Dual-Level Processing
# Purpose: Download WASH survey data from KoboToolbox (household + container levels)
# Date: 2026-02-05
#
# Output:
# 1. Household-level dataset (~369 rows) via Export API
#    - English column labels (via lang = "English (en)")
#    - Multiple_select summary columns + boolean indicators (via multi_sel = "both")
#    - Optional: Arabic free-text columns replaced with English translations
#               if data/wash_survey_arabic_content_final.xlsx exists
#
# 2. Container-level dataset (~882 rows) via /data.json endpoint
#    - Expanded container_repeat groups
#    - All household context fields included
#    - Multiple_select processing done inline
#
# Approach: Dual-source strategy to get both analytical levels

# Libraries -----
library(tidyverse)
library(httr)
library(yaml)
library(here)
library(readxl)
library(writexl)
library(glue)
library(janitor)
library(jsonlite)  # Parse JSON from /data.json endpoint

# Color palettes Global WASH Cluster
GWC_PALETTE_GENERAL <- c("#009999", "#333333", "#000000")
GWC_PALETTE_COMPLEMENTARY <- c("#024e6C", "#383F48", "#8CbFbF", "#ffb340", "#e36159")
GWC_PALETTE_WATER_SANITATION_HYGIENE <- c("#28A1d2", "#532F87", "#008d48")

# Configuration -----
kobo_config_path <- here("config.yaml")
mapping_file_path <- here("data", "Kobo version_02-Feb-2026.xlsx")

config <- read_yaml(kobo_config_path)

# Download household-level data using Kobo Export API -----
# Step 1: Create export task
export_url <- glue("https://{config$kobo$url}/api/v2/assets/{config$kobo$asset_id}/exports/")

export_response <- POST(
  export_url,
  authenticate(config$kobo$user, config$kobo$password, type = "basic"),
  body = list(
    type = "xls",
    lang = "English (en)",
    fields_from_all_versions = FALSE,
    hierarchy_in_labels = FALSE,
    group_sep = "/",
    multiple_select = "both",
    include_media_url = FALSE
  ),
  encode = "json",
  timeout(120)
)

stop_for_status(export_response, task = "create export")

export_data <- content(export_response)
export_uid <- export_data$uid
message(glue("Export task created: {export_uid}"))

# Step 2: Wait for export to complete and get download URL
max_attempts <- 30
attempt <- 1
export_ready <- FALSE

while (attempt <= max_attempts && !export_ready) {
  Sys.sleep(2)

  status_url <- glue("https://{config$kobo$url}/api/v2/assets/{config$kobo$asset_id}/exports/{export_uid}/")
  status_response <- GET(
    status_url,
    authenticate(config$kobo$user, config$kobo$password, type = "basic")
  )

  status_data <- content(status_response)

  if (!is.null(status_data$result)) {
    download_url <- status_data$result
    export_ready <- TRUE
    message("Export ready for download")
  } else {
    attempt <- attempt + 1
  }
}

if (!export_ready) {
  stop("Export did not complete within expected time")
}

# Step 3: Download the file
temp_file <- tempfile(fileext = ".xlsx")
download_response <- GET(
  download_url,
  authenticate(config$kobo$user, config$kobo$password, type = "basic"),
  write_disk(temp_file, overwrite = TRUE),
  timeout(120)
)

stop_for_status(download_response, task = "download export file")

# Step 4: Read the Excel file
wash_data <- read_excel(temp_file)
message(glue("Downloaded {nrow(wash_data)} household-level submissions"))

# Clean up temp file
unlink(temp_file)

# ==============================================================================
# HOUSEHOLD DATA PROCESSING - Clean HH-level data first
# ==============================================================================

# Clean column names to lowercase with underscores -----
names(wash_data) <- make_clean_names(names(wash_data))

# Create index lookup for linking to container data (BEFORE removing any columns)
# Note: make_clean_names converts "_id" to "id"
if ("id" %in% names(wash_data)) {
  index_lookup <- wash_data %>%
    select(index, kobo_id = id)
  message(glue("Created index lookup: {nrow(index_lookup)} mappings"))
} else {
  stop("id column not found - cannot create index lookup for container data")
}

# Load survey definitions for value mapping -----
choices_def <- read_excel(mapping_file_path, sheet = "choices")

# Apply value mapping for select_one questions (safety fallback) -----
mapping <- setNames(
  choices_def[["label::English (en)"]],
  choices_def[["name"]]
)

wash_data <- wash_data %>%
  mutate(across(where(is.character), ~ coalesce(mapping[.x], .x)))

# Fix multiple_select summary column separators (space → semicolon) -----
# The Kobo API uses space to separate multiple selected options in summary columns.
# Since option labels themselves contain spaces (e.g., "Public tap"), we need to
# intelligently replace only the spaces BETWEEN options, not within option labels.
#
# Strategy: Replace spaces that are followed by a capital letter (start of next option)
# Example: "Public tap Water truck" → "Public tap; Water truck"

# Identify multiple_select summary columns by finding columns with boolean indicators
all_cols <- names(wash_data)

summary_cols <- all_cols %>%
  keep(~ {
    # If column X has boolean columns named X_something, then X is a summary column
    potential_bool_pattern <- paste0("^", .x, "_")
    has_bool_indicators <- any(str_detect(all_cols, potential_bool_pattern))
    has_bool_indicators && is.character(wash_data[[.x]])
  })

message(glue("Found {length(summary_cols)} multiple_select summary columns to process"))

# Replace space separator with semicolon in summary columns
if (length(summary_cols) > 0) {
  wash_data <- wash_data %>%
    mutate(across(all_of(summary_cols), ~ {
      # Pattern: (?<=\w) = preceded by word character
      #          (?=[A-Z]) = followed by capital letter (start of next option)
      # This replaces "far Waterpoints" → "far; Waterpoints"
      # but keeps "Public tap" unchanged
      str_replace_all(.x, "(?<=\\w) (?=[A-Z])", "; ")
    }))
}

# Process binary → multi-select pairs -----
# Convert "No" answers in binary questions to unified multi-select options

# Define all binary → multi-select pairs
# Note: trigger_value uses English labels (after value mapping at line 135-136)
binary_multiselect_pairs <- tribble(
  ~binary_col, ~multiselect_col, ~trigger_value, ~fill_value, ~boolean_suffix,
  "hh_ws_1_2_1_does_your_household_have_problems_related_to_access_to_water_if_yes_which_ones", "if_yes_follow_with_the_list", "Yes", "No", "no",
  "hh_s_2_1_2_do_you_have_problems_related_to_sanitation_facilities_latrines_toilets_if_yes_which_ones", "if_yes_select_multiple", "Yes", "No", "no",
  "hh_s_2_6_has_anyone_in_your_household_observed_open_defecation_in_the_area", "hh_s_2_6_1_if_yes_a_please_specify_who_was_observed_practicing_open_defecation", "Yes", "No", "no",
  "hh_s_2_6_has_anyone_in_your_household_observed_open_defecation_in_the_area", "hh_s_2_6_1_1_if_yes_b_when_was_open_defecation_most_often_observed", "Yes", "No", "no",
  "hh_h_4_1_does_your_household_have_problems_related_to_hygiene_items_soap_feminine_hygiene_products_baby_diapers_toothpaste_brush_if_yes_which_ones", "hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items", "Yes", "No", "no",
  "hh_h_4_2_2_do_you_have_enough_soap_at_household_for_all_purposes", "hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap", "No", "Yes", "yes"
)

# Process each pair
for (i in seq_len(nrow(binary_multiselect_pairs))) {
  pair <- binary_multiselect_pairs[i, ]

  binary_col <- pair$binary_col
  multiselect_col <- pair$multiselect_col
  trigger_value <- pair$trigger_value
  fill_value <- pair$fill_value
  boolean_col <- paste0(multiselect_col, "_", pair$boolean_suffix)

  # Check if columns exist
  if (binary_col %in% names(wash_data) && multiselect_col %in% names(wash_data)) {

    # Fill multi-select summary with fill_value when binary != trigger
    wash_data <- wash_data %>%
      mutate(
        !!multiselect_col := if_else(
          .data[[binary_col]] != trigger_value & (is.na(.data[[multiselect_col]]) | .data[[multiselect_col]] == ""),
          fill_value,
          .data[[multiselect_col]]
        )
      )

    # Create boolean indicator column
    wash_data <- wash_data %>%
      mutate(
        !!boolean_col := as.integer(.data[[multiselect_col]] == fill_value)
      )

    # Relocate boolean column immediately after summary column
    wash_data <- wash_data %>%
      relocate(all_of(boolean_col), .after = all_of(multiselect_col))

    message(glue("Processed pair: {binary_col} → {multiselect_col} (added {boolean_col})"))
  }
}

# Process single-select fill operations -----
# Replace generic "Yes" with specific details and fill downstream columns

# Step 1 & 2: Latrine damaged question
# Replace "Yes" with specific details (Damaged/Full/Non-functional)
# Then fill downstream "use another latrine" question with these values
latrine_col <- "hh_s_2_3_in_the_last_30_days_was_the_latrine_you_used_damaged_non_functional_or_full"
specify_col <- "if_yes_then_specify"
use_another_col <- "did_you_have_to_use_another_latrine_as_a_result"

if (all(c(latrine_col, specify_col, use_another_col) %in% names(wash_data))) {

  # Replace "Yes" with specific answer (Damaged/Full/Non-functional)
  wash_data <- wash_data %>%
    mutate(
      !!latrine_col := if_else(
        .data[[latrine_col]] == "Yes" & !is.na(.data[[specify_col]]),
        .data[[specify_col]],
        .data[[latrine_col]]
      )
    )

  # Fill empty/NA in use_another with values from latrine_damaged
  wash_data <- wash_data %>%
    mutate(
      !!use_another_col := if_else(
        is.na(.data[[use_another_col]]),
        .data[[latrine_col]],
        .data[[use_another_col]]
      )
    )

  message(glue("Processed single-select fill: {latrine_col} (Yes → {specify_col}) → {use_another_col}"))
}

# Clean string values (remove control characters, prevent Excel issues) -----
wash_data <- wash_data %>%
  mutate(across(where(is.character), ~ {
    cleaned <- str_replace_all(.x, "[\\x00-\\x1f]", "")
    str_trunc(cleaned, width = 32000, ellipsis = "...")
  }))

# Data cleaning and filtering -----

# Columns to remove: Kobo metadata and survey administration fields
cols_to_remove <- c(
  # Organization-specific columns
  "international_rescue_committee_irc",
  "triangle_generation_humanitaire_tgh",
  "save_the_children_sci",
  "solidarites_international_si",
  # Survey administration
  "hello_my_name_is_xxx_and_i_work_with_org_name_i_would_like_to_ask_you_a_few_questions_to_better_understand_the_water_sanitation_and_hygiene_situation_in_your_location_the_survey_takes_around_10_15_minutes_you_can_stop_at_any_time_or_skip_questions_if_you_want_there_s_no_compensation_for_this_survey_and_your_responses_will_not_affect_any_future_assistance_this_survey_is_not_a_registration_survey_do_you_have_any_questions",
  "do_you_consent_to_be_interviewed",
  "thank_you_for_your_time_we_will_not_continue_with_the_survey",
  # GPS coordinates (individual components - redundant with geolocation)
  "gps_coordinates",
  "gps_coordinates_latitude",
  "gps_coordinates_longitude",
  "gps_coordinates_altitude",
  "gps_coordinates_precision"
)

# Move index to beginning
wash_data <- wash_data %>%
  relocate(index) %>%
  # Remove columns 2-3 (former positions 1-2 before index moved)
  select(-c(2, 3))

# Find where 'id' column starts (metadata begins here) - after previous removals
id_position <- which(names(wash_data) == "id")

wash_data <- wash_data %>%
  # Remove all columns from 'id' onwards (all consecutive metadata at end)
  {if (length(id_position) > 0 && id_position > 0) select(., 1:(id_position - 1)) else .} %>%
  # Filter out non-consented interviews (before removing consent column)
  filter(!str_starts(do_you_consent_to_be_interviewed, "No")) %>%
  # Remove survey administration columns
  select(-any_of(cols_to_remove)) %>%
  # Create unified household head gender variable
  mutate(
    gender_of_the_househld = case_when(
      str_starts(is_the_responder_head_of_the_household, "Yes") ~ gender_of_the_respondent,
      str_starts(is_the_responder_head_of_the_household, "No") ~ specify_the_gender_of_the_househld,
      TRUE ~ NA_character_
    ),
    .after = specify_the_gender_of_the_househld
  ) %>%
  # Move index to the beginning
  relocate(index)

message(glue("After filtering: {nrow(wash_data)} consented households"))

# ==============================================================================
# OPTIONAL: LOAD PRE-TRANSLATED ARABIC CONTENT
# ==============================================================================
# Purpose: Replace Arabic free-text columns with English translations
# File: data/wash_survey_arabic_content_final.xlsx
# Structure: index + 18 Arabic columns + 18 _en translation columns
# If file missing, original Arabic content is preserved

translation_file <- here("data", "wash_survey_arabic_content_final.xlsx")
arabic_translated <- FALSE

if (file.exists(translation_file)) {

  message("\nLoading pre-translated Arabic content...")

  # Load translation file
  translations <- read_excel(translation_file)
  message(glue("  Loaded: {nrow(translations)} rows × {ncol(translations)} columns"))

  # Clean column names to match wash_data (same process as line 112)
  names(translations) <- make_clean_names(names(translations))

  # Define Arabic column patterns (same as line 418-423)
  arabic_patterns <- c(
    "^if_other",
    "^if_others",
    "^comments",
    "^hh_fc_7_1_is_there_anything_else"
  )

  # Identify _en translation columns
  en_cols <- names(translations) %>%
    keep(~ str_detect(.x, paste(arabic_patterns, collapse = "|")) &
           str_ends(.x, "_en"))

  message(glue("  Found {length(en_cols)} translated columns"))

  # Select only index + _en columns, then remove _en suffix
  translations_clean <- translations %>%
    select(index, all_of(en_cols)) %>%
    rename_with(~ str_remove(.x, "_en$"), ends_with("_en"))

  # Validate column alignment with wash_data
  arabic_cols_in_wash <- names(wash_data) %>%
    keep(~ str_detect(.x, paste(arabic_patterns, collapse = "|")))

  translated_cols <- setdiff(names(translations_clean), "index")
  missing_in_wash <- setdiff(translated_cols, arabic_cols_in_wash)

  if (length(missing_in_wash) > 0) {
    warning(glue("Translation columns not found in wash_data: {paste(missing_in_wash, collapse = ', ')}"))
    translations_clean <- translations_clean %>% select(-any_of(missing_in_wash))
    translated_cols <- setdiff(names(translations_clean), "index")
  }

  # Merge translations into wash_data (replace Arabic with English)
  wash_data <- wash_data %>%
    rows_update(translations_clean, by = "index", unmatched = "ignore")

  arabic_translated <- TRUE
  message(glue("  Replaced {length(translated_cols)} Arabic columns with English translations"))
  message(glue("  Coverage: {nrow(translations_clean)} of {nrow(wash_data)} households\n"))

} else {
  message("Translation file not found: keeping original Arabic content\n")
}

# ==============================================================================
# CONTAINER DATA SECTION - Extract repeat group data
# ==============================================================================
# Purpose: Download and expand container_repeat group (882 containers)
# Note: Export API does not expand repeat groups, so we use /data.json endpoint

message("\n=== Downloading container-level data ===")

data_json_url <- glue("https://{config$kobo$url}/api/v2/assets/{config$kobo$asset_id}/data.json")

container_response <- GET(
  data_json_url,
  authenticate(config$kobo$user, config$kobo$password, type = "basic"),
  timeout(120)
)

stop_for_status(container_response, task = "download container data")

json_text <- content(container_response, as = "text", encoding = "UTF-8")
parsed <- fromJSON(json_text, flatten = TRUE, simplifyDataFrame = TRUE)
wash_data_container <- as_tibble(parsed$results)

message(glue("Downloaded {nrow(wash_data_container)} household records for expansion"))

# Identify container repeat column(s)
container_cols <- names(wash_data_container) %>%
  keep(~ str_detect(.x, "container_repeat"))

if (length(container_cols) == 0) {
  stop("No container_repeat columns found in data")
}

# Expand the first container repeat column found
container_col <- container_cols[1]
message(glue("Expanding repeat group: {container_col}"))

wash_data_container <- wash_data_container %>%
  # Keep parent _id for linking
  mutate(parent_kobo_id = `_id`) %>%
  # Expand repeat group
  unnest_longer(all_of(container_col), keep_empty = FALSE) %>%
  unnest_wider(all_of(container_col), names_sep = "_")

message(glue("Expanded to {nrow(wash_data_container)} container records"))

# Clean column names: extract leaf names and standardize
clean_names <- names(wash_data_container) %>%
  map_chr(~ {
    # Don't transform parent_kobo_id
    if (.x == "parent_kobo_id") {
      return(.x)
    }
    str_extract(.x, "[^/]+$") %>%
      make_clean_names()
  })

names(wash_data_container) <- make.unique(clean_names, sep = "_")

# Load survey definitions (should already be loaded from HH processing)
if (!exists("choices_def")) {
  choices_def <- read_excel(mapping_file_path, sheet = "choices")
}

# Process container_use (only select_multiple field we need)
# Load choices for container_use
container_use_choices <- choices_def %>%
  filter(list_name == "container_use") %>%
  select(xml_code = name, english_label = `label::English (en)`)

if ("container_use" %in% names(wash_data_container)) {
  # Convert container_use summary column: XML codes → English labels
  wash_data_container <- wash_data_container %>%
    mutate(
      container_use = map_chr(container_use, function(val) {
        if (is.na(val) || val == "") return(NA_character_)
        codes <- str_trim(str_split(val, " ")[[1]])
        labels <- container_use_choices$english_label[match(codes, container_use_choices$xml_code)]
        paste(na.omit(labels), collapse = "; ")
      })
    )

  # Create boolean indicators for container_use
  wash_data_container <- wash_data_container %>%
    mutate(
      container_use_drinking = as.integer(str_detect(container_use, "Drinking")),
      container_use_domestic = as.integer(str_detect(container_use, "Domestic"))
    )

  message("Processed container_use: created 2 boolean columns")
} else {
  warning("container_use column not found in container data")
}

# Map parent_kobo_id to sequential household index
wash_data_container <- wash_data_container %>%
  left_join(index_lookup %>% rename(parent_kobo_id = kobo_id), by = "parent_kobo_id") %>%
  rename(parent_index = index)  # Sequential HH index (1-371)

# Create sequential container index (1-867)
wash_data_container <- wash_data_container %>%
  mutate(index = row_number()) %>%
  select(-parent_kobo_id)  # Clean up temporary column

# Map select_one codes to English labels for container fields
mapping <- setNames(
  choices_def[["label::English (en)"]],
  choices_def[["name"]]
)

# Select only required container fields
container_fields <- c(
  "index",                    # Container's sequential index (1-867)
  "parent_index",             # Link to household (1-371)
  "container_type",           # select_one
  "container_use",            # select_multiple summary
  "container_use_drinking",   # Boolean
  "container_use_domestic",   # Boolean
  "volume_liters",            # Numeric
  "number_of_containers",     # Integer
  "frequency_filled",         # select_one
  "fill_level"                # select_one (will convert to numeric)
)

wash_data_container <- wash_data_container %>%
  select(any_of(container_fields)) %>%
  # Convert XML codes to English for select_one fields
  mutate(across(c(any_of(c("container_type", "frequency_filled", "fill_level"))), ~ coalesce(mapping[.x], .x)))

# Convert fill_level to numeric (replace character column)
wash_data_container <- wash_data_container %>%
  mutate(
    fill_level = case_when(
      str_detect(fill_level, "Full|full") ~ 1.0,
      str_detect(fill_level, "¾|three.quarter") ~ 0.75,
      str_detect(fill_level, "½|half") ~ 0.5,
      str_detect(fill_level, "¼|quarter") ~ 0.25,
      TRUE ~ NA_real_
    )
  )

message(glue("Converted fill_level to numeric: {sum(!is.na(wash_data_container$fill_level))} non-missing values"))

# Select required household fields from main HH dataset
hh_context <- wash_data %>%
  select(
    parent_index = index,  # Rename for joining
    camp_name,
    age_of_hh_respondent,
    gender_of_the_househld,
    did_people_arrive_two_weeks_ago_into_tawila,
    total_no_of_people_in_hh,
    do_you_have_members_less_than_5_years_old,
    do_you_have_members_with_pregnant_or_lactating_women,
    do_you_have_members_with_child_that_is_currently_receiving_malnutrition_treatment,
    no_of_people_with_disabilities_in_hh_optional,
    hh_ws_1_1_what_is_the_primary_source_of_water_used_by_your_household_for_drinking,
    hh_ws_1_1_1_what_is_the_secondary_source_of_water_used_by_your_household_for_drinking,
    hh_ws_1_2_does_your_household_currently_have_enough_water_for_drinking_and_cooking,
    hh_ws_1_2_1_does_your_household_currently_have_enough_water_for_other_domestic_purposes_e_g_bathing_washing_etc
  )

# Join household context to container data
# Using inner_join to automatically filter out containers from non-consented households
wash_data_container <- wash_data_container %>%
  inner_join(hh_context, by = "parent_index") %>%
  # Reorder: indices first, household context, then container fields
  relocate(index, parent_index, camp_name)

message(glue("Container data (consented households only): {nrow(wash_data_container)} rows × {ncol(wash_data_container)} columns"))

# Save container outputs (Excel + RDS)
write_xlsx(wash_data_container, here("output", "wash_survey_container_level.xlsx"))
saveRDS(wash_data_container, here("output", "wash_survey_container_level.rds"))

message(glue("Saved: output/wash_survey_container_level.xlsx"))
message(glue("       {nrow(wash_data_container)} containers × {ncol(wash_data_container)} columns\n"))

# ---- Extract Arabic Content Columns ----
# Purpose: Separate Arabic free-text responses for translation/review
# Columns: if_other*, if_others*, comments*, hh_fc_7_1_is_there_anything_else*
# Output: output/wash_survey_arabic_content.xlsx
# Note: SKIPPED if pre-translated content was already loaded

if (!arabic_translated) {

  # Pre-flight validation
  if (!"index" %in% names(wash_data)) {
    stop("Expected 'index' column not found in wash_data. Data structure may have changed.")
  }

  message("\nExtracting Arabic content columns...")
message(glue("   Source dataset: {nrow(wash_data)} rows × {ncol(wash_data)} columns"))

# Identify Arabic content columns by pattern matching
arabic_patterns <- c(
  "^if_other",
  "^if_others",
  "^comments",
  "^hh_fc_7_1_is_there_anything_else"
)

arabic_cols <- names(wash_data) %>%
  keep(~ str_detect(.x, paste(arabic_patterns, collapse = "|")))

message(glue("   Found {length(arabic_cols)} Arabic content columns"))

# Conditional execution: only proceed if Arabic columns found
if (length(arabic_cols) == 0) {
  warning("No Arabic content columns found matching patterns: ",
          paste(arabic_patterns, collapse = ", "))
  message("   Skipping Arabic content extraction\n")
} else {

  # Verify column name uniqueness (defensive check)
  if (any(duplicated(arabic_cols))) {
    duplicated_names <- arabic_cols[duplicated(arabic_cols)]
    warning(glue("Duplicate column names detected: {paste(duplicated_names, collapse = ', ')}"))
  }

  # Create Arabic content dataframe
  arabic_content <- wash_data %>%
    select(index, all_of(arabic_cols)) %>%
    # Sort columns: index first, then alphabetical for consistency
    select(index, sort(tidyselect::peek_vars()[-1])) %>%
    # Filter: keep only rows with at least one non-empty Arabic field
    filter(if_any(-index, ~ !is.na(.x) & .x != ""))

  # Calculate statistics
  message(glue("   Extracted: {nrow(arabic_content)} rows with non-empty Arabic content"))

  # Export with error handling
  output_file <- here("output", "wash_survey_arabic_content.xlsx")


  write_xlsx(
    arabic_content,
    path = output_file,
    format_headers = TRUE
  )
  message(glue("   Saved: {basename(output_file)}"))
  message(glue("   Dimensions: {nrow(arabic_content)} rows × {ncol(arabic_content)} columns (index + {ncol(arabic_content) - 1} Arabic fields)\n"))

}

} else {
  message("\nSkipping Arabic content extraction (using pre-translated content)")
}

# ==============================================================================
# SURVEY-WEIGHTED ANALYSIS: WATER SUPPLY INDICATORS
# ==============================================================================

library(srvyr)
message("\n=== Starting survey-weighted analysis for Water Supply indicators ===")

# ---- Data Preparation for Survey Analysis ----

# Convert boolean columns to numeric (handle mixed integer 0/1 and character "0"/"1")
wash_data <- wash_data %>%
  mutate(across(
    c(starts_with("if_yes_follow_with_the_list_"),
      starts_with("hh_ws_1_2_2_"),
      starts_with("hh_ws_1_2_3_")),
    ~ case_when(
      is.numeric(.x) ~ as.numeric(.x),
      .x == "1" ~ 1,
      .x == "0" ~ 0,
      TRUE ~ NA_real_
    )
  ))

# Calculate post-stratification weights
camp_pops <- tibble(
  camp_name = c("Camp A", "Camp B", "Camp C", "Camp D"),
  pop_n = c(20142, 21000, 12504, 42050)
) %>%
  mutate(pop_pct = pop_n / sum(pop_n))

wash_data <- wash_data %>%
  group_by(camp_name) %>%
  mutate(sample_pct = n() / nrow(wash_data)) %>%
  ungroup() %>%
  left_join(camp_pops, by = "camp_name") %>%
  mutate(weight = pop_pct / sample_pct)

# Create pseudo-clusters for DEFF adjustment (DEFF = 2.0)
# Clusters must be nested within strata (camps)
wash_data <- wash_data %>%
  group_by(camp_name) %>%
  mutate(
    pseudo_cluster = rep(
      1:ceiling(n() / sqrt(2.0)),
      length.out = n()
    )
  ) %>%
  ungroup()

# Create survey design object (nest=TRUE because clusters are numbered within camps)
survey_design <- wash_data %>%
  as_survey_design(
    strata = camp_name,
    ids = pseudo_cluster,
    weights = weight,
    nest = TRUE
  )

# Create output directories
dir.create(here("output", "plots"), recursive = TRUE, showWarnings = FALSE)

message(glue("  Survey design created: {nrow(wash_data)} households, effective n ≈ {round(nrow(wash_data) / 2.0, 1)}"))

# ---- Helper Function: Standardized Water Indicator Plots ----

create_water_bar_plot <- function(data, x_var, y_var, title, subtitle,
                                  x_label = "Percentage of Households",
                                  reference_line = NULL,
                                  x_limits = c(0, NA),
                                  label_position = "none") {
  p <- ggplot(data, aes(x = {{ x_var }}, y = reorder({{ y_var }}, {{ x_var }}))) +
    geom_col(fill = "#28A1d2", width = 0.7) +
    geom_errorbar(aes(xmin = ci_lower_pct, xmax = ci_upper_pct),
                  width = 0.3, linewidth = 0.5, color = "#888888") +
    labs(title = title, subtitle = subtitle, x = x_label, y = NULL) +
    scale_x_continuous(
      expand = expansion(mult = c(0, if_else(label_position == "outside", 0.15, 0.1))),
      limits = x_limits,
      labels = scales::label_percent(scale = 1)
    ) +
    theme_minimal(base_size = 12) +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      plot.subtitle = element_text(color = "grey40", size = 11),
      panel.grid.major.y = element_blank(),
      panel.grid.minor = element_blank(),
      axis.text = element_text(size = 10)
    )

  # Add percentage labels based on position
  if (label_position == "outside") {
    p <- p + geom_text(aes(label = sprintf("%d%%", {{ x_var }})),
                       hjust = -0.2, size = 3.5)
  } else if (label_position == "inside") {
    p <- p + geom_text(aes(label = sprintf("%d%%", {{ x_var }})),
                       hjust = 1.1, size = 3.5, color = "white", fontface = "bold")
  }

  if (!is.null(reference_line)) {
    p <- p + geom_vline(xintercept = reference_line,
                       linetype = "dashed", color = "red", linewidth = 0.7)
  }

  return(p)
}

# ---- Indicator 1.1: Primary Drinking Water Source ----

indicator_1.1 <- tryCatch({
  results_1.1 <- survey_design %>%
    filter(!is.na(hh_ws_1_1_what_is_the_primary_source_of_water_used_by_your_household_for_drinking)) %>%
    group_by(water_source = hh_ws_1_1_what_is_the_primary_source_of_water_used_by_your_household_for_drinking) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      n_effective = n(),
      .groups = "drop"
    ) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    arrange(desc(estimate_pct))

  if (abs(sum(results_1.1$estimate_pct) - 100) > 5) {
    warning("Indicator 1.1: Categories sum to ", round(sum(results_1.1$estimate_pct), 1), "%, expected ~100%")
  }

  plot_1.1 <- create_water_bar_plot(
    data = results_1.1,
    x_var = estimate_pct,
    y_var = water_source,
    title = "Indicator 1.1: Primary Drinking Water Source",
    subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)"),
    label_position = "outside"
  )

  ggsave(here("output", "plots", "water_indicator_1.1.png"),
         plot = plot_1.1, width = 8, height = 6, dpi = 300, bg = "white")

  message("  [OK] Indicator 1.1: Primary Water Source")
  results_1.1

}, error = function(e) {
  message("  [ERROR] Indicator 1.1: ", e$message)
  return(NULL)
})

# ---- Indicator 1.2: Water Sufficiency ----

indicator_1.2 <- tryCatch({
  results_1.2 <- survey_design %>%
    summarise(
      sufficient_drinking_cooking_pct = survey_mean(
        hh_ws_1_2_does_your_household_currently_have_enough_water_for_drinking_and_cooking == "Yes",
        vartype = "ci", na.rm = TRUE
      ) * 100,
      sufficient_domestic_pct = survey_mean(
        hh_ws_1_2_1_does_your_household_currently_have_enough_water_for_other_domestic_purposes_e_g_bathing_washing_etc == "Yes",
        vartype = "ci", na.rm = TRUE
      ) * 100,
      sufficient_both_pct = survey_mean(
        hh_ws_1_2_does_your_household_currently_have_enough_water_for_drinking_and_cooking == "Yes" &
        hh_ws_1_2_1_does_your_household_currently_have_enough_water_for_other_domestic_purposes_e_g_bathing_washing_etc == "Yes",
        vartype = "ci", na.rm = TRUE
      ) * 100,
      n_unweighted = unweighted(n()),
      n_effective = n()
    )

  # Manual reshaping for clarity
  results_1.2_plot <- tibble(
    measure_label = factor(
      c("Drinking/Cooking", "Other Domestic", "Both Purposes"),
      levels = c("Drinking/Cooking", "Other Domestic", "Both Purposes")
    ),
    estimate_pct = c(
      results_1.2$sufficient_drinking_cooking_pct,
      results_1.2$sufficient_domestic_pct,
      results_1.2$sufficient_both_pct
    ),
    ci_lower_pct = c(
      results_1.2$sufficient_drinking_cooking_pct_low,
      results_1.2$sufficient_domestic_pct_low,
      results_1.2$sufficient_both_pct_low
    ),
    ci_upper_pct = c(
      results_1.2$sufficient_drinking_cooking_pct_upp,
      results_1.2$sufficient_domestic_pct_upp,
      results_1.2$sufficient_both_pct_upp
    )
  ) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))

  plot_1.2 <- ggplot(results_1.2_plot, aes(x = estimate_pct, y = measure_label)) +
    geom_col(fill = "#28A1d2", width = 0.6) +
    geom_errorbar(aes(xmin = ci_lower_pct, xmax = ci_upper_pct), width = 0.3, color = "#888888") +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)), hjust = -0.2, size = 3.5) +
    labs(
      title = "Indicator 1.2: Water Sufficiency",
      subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)"),
      x = "Percentage of Households", y = NULL
    ) +
    scale_x_continuous(expand = expansion(mult = c(0, 0.15)), limits = c(0, 100)) +
    theme_minimal(base_size = 12)

  ggsave(here("output", "plots", "water_indicator_1.2.png"),
         plot = plot_1.2, width = 8, height = 5, dpi = 300, bg = "white")

  message("  [OK] Indicator 1.2: Water Sufficiency")

  results_1.2_plot %>%
    rename(indicator_category = measure_label) %>%
    mutate(n_unweighted = results_1.2$n_unweighted, n_effective = results_1.2$n_effective)

}, error = function(e) {
  message("  [ERROR] Indicator 1.2: ", e$message)
  return(NULL)
})

# ---- Indicator 1.3: Water Access Problems ----

indicator_1.3 <- tryCatch({
  # Include ALL problem columns including "no" (exclude only parent and "don't know")
  problem_cols <- names(wash_data)[str_detect(names(wash_data), "^if_yes_follow_with_the_list_")] %>%
    setdiff(c("if_yes_follow_with_the_list", "if_yes_follow_with_the_list_don_t_know"))

  # Calculate % for each problem type (including "No problems")
  problem_results <- map_dfr(problem_cols, function(col) {
    survey_design %>%
      summarise(
        problem_type = col,
        estimate_pct = survey_mean(!!sym(col) == 1, vartype = "ci", na.rm = TRUE) * 100,
        n_unweighted = unweighted(sum(!!sym(col) == 1, na.rm = TRUE))
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      problem_label = str_remove(problem_type, "if_yes_follow_with_the_list_") %>%
        str_replace_all("_", " ") %>%
        str_to_sentence() %>%
        # Special handling for "No" → "No problems"
        {if_else(. == "No", "No problems", .)} %>%
        str_wrap(width = 50)
    ) %>%
    arrange(desc(estimate_pct))  # Show all categories, sorted by prevalence

  plot_1.3 <- create_water_bar_plot(
    data = problem_results,
    x_var = estimate_pct,
    y_var = problem_label,
    title = "Indicator 1.3: Water Access Problems",
    subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nAll responses shown (multi-select allows overlaps)"),
    label_position = "outside"
  )

  ggsave(here("output", "plots", "water_indicator_1.3.png"),
         plot = plot_1.3, width = 10, height = 8, dpi = 300, bg = "white")

  message("  [OK] Indicator 1.3: Water Access Problems")

  problem_results %>%
    select(indicator_category = problem_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 1.3: ", e$message)
  return(NULL)
})

# ---- Indicator 1.4: Coping Mechanisms ----

indicator_1.4 <- tryCatch({
  coping_cols <- names(wash_data)[str_detect(names(wash_data), "^hh_ws_1_2_2_")] %>%
    setdiff(c("hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water",
              "hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_don_t_know",
              "hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_other_please_list"))

  coping_results <- map_dfr(coping_cols, function(col) {
    survey_design %>%
      summarise(
        mechanism = col,
        estimate_pct = survey_mean(!!sym(col) == 1, vartype = "ci", na.rm = TRUE) * 100
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      mechanism_label = str_remove(mechanism, "hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water_") %>%
        str_replace_all("_", " ") %>%
        str_to_sentence() %>%
        str_wrap(width = 50)
    ) %>%
    arrange(desc(estimate_pct)) %>%
    slice_head(n = 10)

  plot_1.4 <- create_water_bar_plot(
    data = coping_results,
    x_var = estimate_pct,
    y_var = mechanism_label,
    title = "Indicator 1.4: Water-Related Coping Mechanisms (Top 10)",
    subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)"),
    label_position = "outside"
  )

  ggsave(here("output", "plots", "water_indicator_1.4.png"),
         plot = plot_1.4, width = 10, height = 7, dpi = 300, bg = "white")

  message("  [OK] Indicator 1.4: Coping Mechanisms")

  coping_results %>%
    select(indicator_category = mechanism_label, estimate_pct, ci_lower_pct, ci_upper_pct)

}, error = function(e) {
  message("  [ERROR] Indicator 1.4: ", e$message)
  return(NULL)
})

# ---- Indicator 1.6: Time to Fetch Water (Categorical) ----

indicator_1.6 <- tryCatch({
  fetch_cols <- names(wash_data)[str_detect(names(wash_data), "^hh_ws_1_2_3_")] %>%
    setdiff(c("hh_ws_1_2_3_how_long_does_it_take_to_go_to_your_main_water_source_fetch_water_and_return_including_queuing_at_the_water_source",
              "hh_ws_1_2_3_how_long_does_it_take_to_go_to_your_main_water_source_fetch_water_and_return_including_queuing_at_the_water_source_don_t_know"))

  fetch_results <- map_dfr(fetch_cols, function(col) {
    survey_design %>%
      summarise(
        time_category = col,
        estimate_pct = survey_mean(!!sym(col) == 1, vartype = "ci", na.rm = TRUE) * 100
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      category_order = case_when(
        str_detect(time_category, "on_premises") ~ 1,
        str_detect(time_category, "delivered") ~ 2,
        str_detect(time_category, "less_than_5") ~ 3,
        str_detect(time_category, "between_5_and_15") ~ 4,
        str_detect(time_category, "between_16_and_30") ~ 5,
        str_detect(time_category, "more_than_31") ~ 6
      ),
      category_label = case_when(
        category_order == 1 ~ "On premises",
        category_order == 2 ~ "Delivered",
        category_order == 3 ~ "<5 minutes",
        category_order == 4 ~ "5-15 minutes",
        category_order == 5 ~ "16-30 minutes",
        category_order == 6 ~ ">31 minutes"
      ),
      exceeds_sphere = category_order == 6
    ) %>%
    arrange(category_order)

  if (abs(sum(fetch_results$estimate_pct) - 100) > 5) {
    warning("Indicator 1.6: Categories sum to ", round(sum(fetch_results$estimate_pct), 1), "%, expected ~100%")
  }

  plot_1.6 <- ggplot(fetch_results, aes(x = estimate_pct, y = "Fetch Time",
                                        fill = category_label)) +
    geom_col(position = "stack") +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)),
              position = position_stack(vjust = 0.5),
              color = "white", fontface = "bold", size = 3.5) +
    scale_fill_manual(
      values = c("#004d99", "#0066cc", "#3399ff", "#66b3ff", "#99ccff", "#ff6666"),
      name = "Time Category"
    ) +
    labs(
      title = "Indicator 1.6: Time to Fetch Water (Round Trip)",
      subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)"),
      x = "Percentage of Households",
      y = NULL,
      caption = "Red shading: Exceeds Sphere Standard (>30 minutes)"
    ) +
    scale_x_continuous(expand = c(0, 0)) +
    theme_minimal(base_size = 12) +
    theme(legend.position = "right")

  ggsave(here("output", "plots", "water_indicator_1.6.png"),
         plot = plot_1.6, width = 10, height = 4, dpi = 300, bg = "white")

  message("  [OK] Indicator 1.6: Fetch Time Categories")

  fetch_results %>%
    select(indicator_category = category_label, estimate_pct, ci_lower_pct, ci_upper_pct)

}, error = function(e) {
  message("  [ERROR] Indicator 1.6: ", e$message)
  return(NULL)
})

# ---- Indicator 1.9: FRC Levels ----

indicator_1.9 <- tryCatch({
  results_1.9 <- survey_design %>%
    mutate(
      frc_clean = case_when(
        str_detect(hh_wq_1_3_2_frc_test_result, "^0$|0\\.0") ~ "0.0 mg/l",
        str_detect(hh_wq_1_3_2_frc_test_result, "Below 0\\.2") ~ "Below 0.2 mg/l",
        str_detect(hh_wq_1_3_2_frc_test_result, "0\\.2.*0[,\\.]5") ~ "0.2-0.5 mg/l (TARGET)",
        str_detect(hh_wq_1_3_2_frc_test_result, "0\\.5.*1\\.0") ~ "0.5-1.0 mg/l",
        str_detect(hh_wq_1_3_2_frc_test_result, "More than|>1") ~ ">1.0 mg/l",
        TRUE ~ NA_character_
      )
    ) %>%
    filter(!is.na(frc_clean)) %>%
    group_by(frc_clean) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      n_effective = n(),
      .groups = "drop"
    ) %>%
    mutate(
      frc_order = case_when(
        frc_clean == "0.0 mg/l" ~ 1,
        frc_clean == "Below 0.2 mg/l" ~ 2,
        frc_clean == "0.2-0.5 mg/l (TARGET)" ~ 3,
        frc_clean == "0.5-1.0 mg/l" ~ 4,
        frc_clean == ">1.0 mg/l" ~ 5
      )
    ) %>%
    arrange(frc_order) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      in_target = str_detect(frc_clean, "TARGET"),
      fill_color = if_else(in_target, "#28A1d2", "#8CbFbF")
    )

  pct_in_target <- results_1.9 %>% filter(in_target) %>% pull(estimate_pct)

  plot_1.9 <- ggplot(results_1.9, aes(x = estimate_pct, y = "FRC Level",
                                      fill = fill_color)) +
    geom_col(position = "stack", color = "white", linewidth = 1.5) +
    geom_text(aes(label = sprintf("%s\n%d%%", frc_clean, estimate_pct)),
              position = position_stack(vjust = 0.5),
              color = "white", fontface = "bold", size = 3) +
    scale_fill_identity() +
    labs(
      title = "Indicator 1.9: Free Residual Chlorine (FRC) Levels",
      subtitle = glue("Overall Tawila-wide estimate (n={sum(results_1.9$n_unweighted)} households tested)\nTarget range (0.2-0.5 mg/l): {round(pct_in_target)}%"),
      x = "Percentage of Households",
      y = NULL,
      caption = "Dark blue: Sphere Standard target range (0.2-0.5 mg/l)"
    ) +
    scale_x_continuous(expand = c(0, 0)) +
    theme_minimal(base_size = 12)

  ggsave(here("output", "plots", "water_indicator_1.9.png"),
         plot = plot_1.9, width = 10, height = 4, dpi = 300, bg = "white")

  message("  [OK] Indicator 1.9: FRC Levels")

  results_1.9 %>%
    select(indicator_category = frc_clean, estimate_pct, ci_lower_pct, ci_upper_pct,
           n_unweighted, n_effective)

}, error = function(e) {
  message("  [ERROR] Indicator 1.9: ", e$message)
  return(NULL)
})

# ---- Export Results to Excel ----

message("\n=== Exporting results to Excel ===")

indicator_sheets <- list(
  "1.1 Water Source" = indicator_1.1,
  "1.2 Water Sufficiency" = indicator_1.2,
  "1.3 Access Problems" = indicator_1.3,
  "1.4 Coping Mechanisms" = indicator_1.4,
  "1.6 Fetch Time" = indicator_1.6,
  "1.9 FRC Levels" = indicator_1.9
)

indicator_sheets <- indicator_sheets %>% discard(is.null)

output_file <- here("output", "wash_survey_water_indicators.xlsx")
write_xlsx(indicator_sheets, path = output_file)

message(glue("  Saved: {basename(output_file)} ({length(indicator_sheets)} sheets)"))
message(glue("  Plots: output/plots/water_indicator_*.png ({length(indicator_sheets)} files)\n"))

# ---- Save Main Outputs ----
output_dir <- here("output")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

write_xlsx(wash_data, here("output", "wash_survey_hh_level.xlsx"))
saveRDS(wash_data, here("output", "wash_survey_hh_level.rds"))

message(glue("
=== Processing Complete ===
Household-level: {nrow(wash_data)} rows × {ncol(wash_data)} columns
  → output/wash_survey_hh_level.xlsx
Container-level: {nrow(wash_data_container)} rows × {ncol(wash_data_container)} columns
  → output/wash_survey_container_level.xlsx
Arabic content: output/wash_survey_arabic_content.xlsx
"))
