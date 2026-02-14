# ================================================================================
# SECTION 1: SETUP & CONFIGURATION
# ================================================================================
# Purpose: Load required packages, define color palettes, and read Kobo API credentials
# Output: Environment prepared for data processing
# ================================================================================

# Load required packages
library(tidyverse)
library(httr)
library(yaml)
library(here)
library(readxl)
library(writexl)
library(glue)
library(janitor)
library(jsonlite)  # Parse JSON from /data.json endpoint

# Define Global WASH Cluster color palettes for standardized visualizations
GWC_PALETTE_PRIMARY <- "#009999"  # Teal (all indicators)
GWC_PALETTE_SECONDARY <- "#e36159"  # Red (negatives, Sphere violations)
GWC_PALETTE_NEUTRAL <- "#bdbdbd"  # Grey (neutral/don't know)
GWC_ERROR_BARS <- "#888888"  # Unchanged

# Teal gradient (5 shades, light to dark)
GWC_TEAL_GRADIENT_5 <- c("#b3e0e0", "#80cccc", "#4db8b8", "#1aa3a3", "#009999")

# Teal comparison pair (for gender/category comparisons)
GWC_TEAL_COMPARISON <- c(light = "#80cccc", dark = "#009999")

# Diverging Likert scale (red-teal)
GWC_LIKERT_5 <- c(
  very_negative = "#e36159",
  negative = "#ed9289",
  neutral = "#80cccc",
  positive = "#4db8b8",
  very_positive = "#009999"
)

# Read Kobo API credentials and file paths from configuration
kobo_config_path <- here("config.yaml")
mapping_file_path <- here("data", "Kobo version_02-Feb-2026.xlsx")

config <- read_yaml(kobo_config_path)

# ================================================================================
# SECTION 2: DATA DOWNLOAD - HOUSEHOLD LEVEL
# ================================================================================
# Purpose: Download household-level data from Kobo using Export API with English labels
# Output: Raw household dataset (~371 rows) with boolean indicators for multi-select questions
# ================================================================================

# Create export task for household data
# Step 1: Create export task
export_url <- glue("https://{config$kobo$url}/api/v2/assets/{config$kobo$asset_id}/exports/")

# Send POST request to Kobo API to initiate export
export_response <- POST(
  export_url,
  authenticate(config$kobo$user, config$kobo$password, type = "basic"),
  body = list(
    type = "xls",
    lang = "English (en)",
    fields_from_all_versions = TRUE,
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

# Poll export status until ready or timeout
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

# Download exported file to temporary location
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

# ================================================================================
# SECTION 3: DATA PROCESSING - HOUSEHOLD LEVEL
# ================================================================================
# Purpose: Clean, standardize, and transform household-level data for analysis
# Output: Processed household dataset with consent filtering, unified columns, and clean names
# ================================================================================

# Standardize column names to lowercase with underscores
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

# Load survey definitions for value mapping
choices_def <- read_excel(mapping_file_path, sheet = "choices")

# Map Kobo choice codes to English labels for select_one questions
mapping <- setNames(
  choices_def[["label::English (en)"]],
  choices_def[["name"]]
)

# Apply value mapping to all character columns
wash_data <- wash_data %>%
  mutate(across(where(is.character), ~ coalesce(mapping[.x], .x)))

# Fix multiple_select summary column separators (space → semicolon) -----
# The Kobo API uses space to separate multiple selected options in summary columns.
# Since option labels themselves contain spaces (e.g., "Public tap"), we need to
# intelligently replace only the spaces BETWEEN options, not within option labels.
#
# Strategy: Replace spaces that are followed by a capital letter (start of next option)
# Example: "Public tap Water truck" → "Public tap; Water truck"

# Identify multi-select summary columns (have corresponding boolean columns)
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

# Loop through each pair and create unified boolean columns
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

# Apply final data cleaning: remove metadata, filter consent, standardize columns
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

# ================================================================================
# SECTION 4: OPTIONAL - ARABIC CONTENT INTEGRATION
# ================================================================================
# Purpose: Replace Arabic free-text columns with pre-translated English content
# Output: Household dataset with English translations (if translation file exists)
# ================================================================================
# File: data/wash_survey_arabic_content_final.xlsx
# Structure: index + 18 Arabic columns + 18 _en translation columns
# If file missing, original Arabic content is preserved

translation_file <- here("data", "wash_survey_arabic_content_final.xlsx")
arabic_translated <- FALSE

if (file.exists(translation_file)) {

  message("\nLoading pre-translated Arabic content...")

  # Load pre-translated English content from Excel file
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

  # Replace Arabic free-text columns with English translations
  wash_data <- wash_data %>%
    rows_update(translations_clean, by = "index", unmatched = "ignore")

  arabic_translated <- TRUE
  message(glue("  Replaced {length(translated_cols)} Arabic columns with English translations"))
  message(glue("  Coverage: {nrow(translations_clean)} of {nrow(wash_data)} households\n"))

} else {
  message("Translation file not found: keeping original Arabic content\n")
}

# ================================================================================
# SECTION 5: DATA DOWNLOAD & PROCESSING - CONTAINER LEVEL
# ================================================================================
# Purpose: Download container repeat group data, expand nested records, and create container dataset
# Output: Container-level dataset (867 rows × 23 columns) with household context
# ================================================================================
# Note: Export API does not expand repeat groups, so we use /data.json endpoint

message("\n=== Downloading container-level data ===")

# Download raw JSON data from Kobo API

data_json_url <- glue("https://{config$kobo$url}/api/v2/assets/{config$kobo$asset_id}/data.json")

container_response <- GET(
  data_json_url,
  authenticate(config$kobo$user, config$kobo$password, type = "basic"),
  timeout(120)
)

stop_for_status(container_response, task = "download container data")

# Parse JSON response and convert to tibble
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

# Expand nested container repeat group into individual container rows
container_col <- container_cols[1]
message(glue("Expanding repeat group: {container_col}"))

wash_data_container <- wash_data_container %>%
  # Keep parent _id for linking
  mutate(parent_kobo_id = `_id`) %>%
  # Expand repeat group
  unnest_longer(all_of(container_col), keep_empty = FALSE) %>%
  unnest_wider(all_of(container_col), names_sep = "_")

message(glue("Expanded to {nrow(wash_data_container)} container records"))

# Extract leaf names from nested paths and standardize formatting
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

# Convert container_use multi-select from XML codes to English labels
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

# Convert fill_level symbols to numeric values for calculations
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

# Extract household context fields to join with container data
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

# Save container-level dataset in Excel and RDS formats
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

# ================================================================================
# SECTION 6: SURVEY-WEIGHTED ANALYSIS - WATER INDICATORS
# ================================================================================
# Purpose: Calculate survey-weighted estimates for Water Supply indicators (1.1-1.9)
# Output: Excel file with 7 indicator sheets and 7 PNG plots
# ================================================================================

# Load survey analysis package
library(srvyr)
message("\n=== Starting survey-weighted analysis for Water Supply indicators ===")

# ---- Data Preparation for Survey Analysis ----

#' Convert boolean indicator columns to numeric (0/1)
#'
#' Uses a guarded approach to only convert columns that are actually
#' boolean-like (numeric or character "0"/"1"), preventing accidental
#' destruction of text columns that share the same prefix.
#'
#' @param data Data frame to process
#' @param prefixes Character vector of column name prefixes to check
#' @return Data frame with boolean columns converted to numeric
convert_boolean_columns <- function(data, prefixes) {
  data %>%
    mutate(across(
      starts_with(prefixes) &
        where(~ is.numeric(.x) || (is.character(.x) && all(na.omit(.x) %in% c("0", "1")))),
      ~ as.numeric(.x)
    ))
}

# Convert water boolean columns to numeric (SAFE approach with where() guard)
wash_data <- convert_boolean_columns(wash_data, c(
  "if_yes_follow_with_the_list_",
  "hh_ws_1_2_2_",
  "hh_ws_1_2_3_"
))

# Calculate post-stratification weights based on actual camp populations
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

#' Create survey design object for Tawila WASH analysis
#'
#' Uses pseudo-clusters based on camp + age groups, with equal weights
#' due to self-weighting proportional allocation design.
#'
#' @param data Household-level data frame with required columns:
#'   - camp_name (strata)
#'   - pseudo_cluster (cluster IDs)
#'   - weight (sampling weights, all = 1)
#' @return Survey design object (srvyr::as_survey_design)
create_survey_design <- function(data) {
  data %>%
    as_survey_design(
      strata = camp_name,
      ids = pseudo_cluster,
      weights = weight,
      nest = TRUE
    )
}

# Create survey design object with pseudo-clusters and post-stratification weights
survey_design <- create_survey_design(wash_data)

# Create output directories
dir.create(here("output", "plots"), recursive = TRUE, showWarnings = FALSE)

message(glue("  Survey design created: {nrow(wash_data)} households, effective n ≈ {round(nrow(wash_data) / 2.0, 1)}"))

# ---- Helper Function: Standardized WASH Indicator Plots ----

#' Create standardized horizontal bar plot for WASH indicators
#'
#' @param data Data frame with indicator results
#' @param x_var X-axis variable (percentage, unquoted)
#' @param y_var Y-axis variable (category, unquoted)
#' @param title Plot title
#' @param subtitle Plot subtitle (typically sample size info)
#' @param x_label X-axis label (default: "Percentage of Households")
#' @param fill_color Bar fill color (hex code)
#' @param reference_line Optional reference line value (default: NULL)
#' @param x_limits X-axis limits (default: c(0, NA))
#' @param label_position Label placement: "none", "outside", "inside"
#' @return ggplot2 object
create_bar_plot <- function(data, x_var, y_var, title, subtitle,
                            x_label = "Percentage of Households",
                            fill_color = "#009999",
                            reference_line = NULL,
                            x_limits = c(0, NA),
                            label_position = "none") {
  p <- ggplot(data, aes(x = {{ x_var }}, y = reorder({{ y_var }}, {{ x_var }}))) +
    geom_col(fill = fill_color, width = 0.7) +
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

  plot_1.1 <- create_bar_plot(
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

# ---- Indicator 1.2: Water Sufficiency for Drinking/Cooking ----

indicator_1.2 <- tryCatch({
  results_1.2 <- survey_design %>%
    summarise(
      yes_pct = survey_mean(
        hh_ws_1_2_does_your_household_currently_have_enough_water_for_drinking_and_cooking == "Yes",
        vartype = "ci", na.rm = TRUE
      ) * 100,
      no_pct = survey_mean(
        hh_ws_1_2_does_your_household_currently_have_enough_water_for_drinking_and_cooking == "No",
        vartype = "ci", na.rm = TRUE
      ) * 100,
      n_unweighted = unweighted(n()),
      n_effective = n()
    )

  # Create stacked bar data
  results_1.2_plot <- tibble(
    category = factor(c("Yes", "No"), levels = c("Yes", "No")),
    estimate_pct = c(results_1.2$yes_pct, results_1.2$no_pct),
    ci_lower_pct = c(results_1.2$yes_pct_low, results_1.2$no_pct_low),
    ci_upper_pct = c(results_1.2$yes_pct_upp, results_1.2$no_pct_upp),
    fill_color = c("#009999", "#e36159"),
    y = "Water Sufficiency"
  ) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))

  # Stacked horizontal bar
  plot_1.2 <- ggplot(results_1.2_plot, aes(x = estimate_pct, y = y, fill = fill_color)) +
    geom_col(position = "stack", color = "white", linewidth = 1.5) +
    scale_fill_identity() +
    geom_text(aes(label = sprintf("%s\n%d%%", category, estimate_pct)),
              position = position_stack(vjust = 0.5), size = 4, color = "white", fontface = "bold") +
    labs(
      title = "Indicator 1.2: Water Sufficiency for Drinking and Cooking",
      subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)"),
      x = "Percentage of Households", y = NULL
    ) +
    scale_x_continuous(limits = c(0, 100), expand = c(0, 0)) +
    theme_minimal(base_size = 12) +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      plot.subtitle = element_text(color = "grey40", size = 11),
      panel.grid = element_blank(),
      axis.text.y = element_blank(),
      axis.ticks = element_blank()
    )

  ggsave(here("output", "plots", "water_indicator_1.2.png"),
         plot = plot_1.2, width = 8, height = 3, dpi = 300, bg = "white")

  message("  [OK] Indicator 1.2: Water Sufficiency (Drinking/Cooking)")

  results_1.2_plot %>%
    select(category, estimate_pct, ci_lower_pct, ci_upper_pct) %>%
    mutate(n_unweighted = results_1.2$n_unweighted, n_effective = results_1.2$n_effective)

}, error = function(e) {
  message("  [ERROR] Indicator 1.2: ", e$message)
  return(NULL)
})

# ---- Indicator 1.2.1: Water Sufficiency for Other Domestic Purposes ----

indicator_1.2.1 <- tryCatch({
  results_1.2.1 <- survey_design %>%
    summarise(
      sufficient_domestic_pct = survey_mean(
        hh_ws_1_2_1_does_your_household_currently_have_enough_water_for_other_domestic_purposes_e_g_bathing_washing_etc == "Yes",
        vartype = "ci", na.rm = TRUE
      ) * 100,

      insufficient_all_uses_pct = survey_mean(
        !is.na(if_no_then_what_needs_are_not_covered) &
        if_no_then_what_needs_are_not_covered == "drinking, cooking and washing/bathing/general use",
        vartype = "ci"
      ) * 100,

      insufficient_basic_needs_pct = survey_mean(
        !is.na(if_no_then_what_needs_are_not_covered) &
        if_no_then_what_needs_are_not_covered == "not enough water for basic needs",
        vartype = "ci"
      ) * 100,

      insufficient_drinking_pct = survey_mean(
        !is.na(if_no_then_what_needs_are_not_covered) &
        if_no_then_what_needs_are_not_covered == "only drinking",
        vartype = "ci"
      ) * 100,

      insufficient_cooking_pct = survey_mean(
        !is.na(if_no_then_what_needs_are_not_covered) &
        if_no_then_what_needs_are_not_covered == "only cooking",
        vartype = "ci"
      ) * 100,

      n_unweighted = unweighted(n()),
      n_effective = n()
    )

  # Create bar chart data with descriptive labels
  results_1.2.1_plot <- tibble(
    category = factor(
      c(
        "Sufficient: Other Domestic",
        "Insufficient: All uses",
        "Insufficient: Basic needs",
        "Insufficient: Only drinking",
        "Insufficient: Only cooking"
      ),
      levels = rev(c(
        "Sufficient: Other Domestic",
        "Insufficient: All uses",
        "Insufficient: Basic needs",
        "Insufficient: Only drinking",
        "Insufficient: Only cooking"
      ))
    ),
    display_label = factor(
      c(
        "Enough for other domestic purposes\n(bathing, washing)",
        "Not enough for drinking, cooking\nand washing/bathing/general use",
        "Not enough for basic needs",
        "Not enough for drinking",
        "Not enough for cooking"
      ),
      levels = rev(c(
        "Enough for other domestic purposes\n(bathing, washing)",
        "Not enough for drinking, cooking\nand washing/bathing/general use",
        "Not enough for basic needs",
        "Not enough for drinking",
        "Not enough for cooking"
      ))
    ),
    estimate_pct = c(
      results_1.2.1$sufficient_domestic_pct,
      results_1.2.1$insufficient_all_uses_pct,
      results_1.2.1$insufficient_basic_needs_pct,
      results_1.2.1$insufficient_drinking_pct,
      results_1.2.1$insufficient_cooking_pct
    ),
    ci_lower_pct = c(
      results_1.2.1$sufficient_domestic_pct_low,
      results_1.2.1$insufficient_all_uses_pct_low,
      results_1.2.1$insufficient_basic_needs_pct_low,
      results_1.2.1$insufficient_drinking_pct_low,
      results_1.2.1$insufficient_cooking_pct_low
    ),
    ci_upper_pct = c(
      results_1.2.1$sufficient_domestic_pct_upp,
      results_1.2.1$insufficient_all_uses_pct_upp,
      results_1.2.1$insufficient_basic_needs_pct_upp,
      results_1.2.1$insufficient_drinking_pct_upp,
      results_1.2.1$insufficient_cooking_pct_upp
    ),
    fill_color = c("#009999", "#e36159", "#e36159", "#e36159", "#e36159")
  ) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))

  # Standard horizontal bar chart with separate bars for each category
  plot_1.2.1 <- ggplot(results_1.2.1_plot, aes(x = estimate_pct, y = display_label)) +
    geom_col(aes(fill = fill_color), width = 0.7) +
    scale_fill_identity() +
    geom_errorbar(aes(xmin = ci_lower_pct, xmax = ci_upper_pct),
                  width = 0.3, color = "#888888") +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)),
              hjust = -0.2, size = 3.5) +
    labs(
      title = "Indicator 1.2.1: Water sufficiency for other domestic purposes",
      subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)"),
      x = "Percentage of Households",
      y = NULL
    ) +
    scale_x_continuous(
      expand = expansion(mult = c(0, 0.15)),
      limits = c(0, 100)
    ) +
    theme_minimal(base_size = 12) +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      plot.subtitle = element_text(color = "grey40", size = 11),
      panel.grid.major.y = element_blank(),
      panel.grid.minor = element_blank(),
      axis.text.y = element_text(size = 10)
    )

  ggsave(here("output", "plots", "water_indicator_1.2.1.png"),
         plot = plot_1.2.1, width = 10, height = 5, dpi = 300, bg = "white")

  message("  [OK] Indicator 1.2.1: Water Sufficiency (Other Domestic)")

  results_1.2.1_plot %>%
    mutate(display_label = as.character(display_label)) %>%
    select(category = display_label, estimate_pct, ci_lower_pct, ci_upper_pct) %>%
    mutate(n_unweighted = results_1.2.1$n_unweighted, n_effective = results_1.2.1$n_effective)

}, error = function(e) {
  message("  [ERROR] Indicator 1.2.1: ", e$message)
  return(NULL)
})

# ---- Indicator 1.3: Water Access Problems ----

indicator_1.3 <- tryCatch({
  # Include ALL problem columns including "no" (exclude only parent and "don't know")
  problem_cols <- names(wash_data)[str_detect(names(wash_data), "^if_yes_follow_with_the_list_")] %>%
    setdiff(c("if_yes_follow_with_the_list", "if_yes_follow_with_the_list_don_t_know"))

  # Calculate % for each problem type (including "No problems")
  # Note: coalesce(col, 0) treats NA as 0, ensuring all 369 HH in denominator
  problem_results <- map_dfr(problem_cols, function(col) {
    survey_design %>%
      summarise(
        problem_type = col,
        estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100,
        n_unweighted = unweighted(sum(coalesce(!!sym(col), 0) == 1))
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

  plot_1.3 <- create_bar_plot(
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

  # Note: coalesce(col, 0) treats NA as 0, ensuring all 369 HH in denominator
  coping_results <- map_dfr(coping_cols, function(col) {
    survey_design %>%
      summarise(
        mechanism = col,
        estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100
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

  plot_1.4 <- create_bar_plot(
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
      values = c(GWC_TEAL_GRADIENT_5, "#e36159"),
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

  # Create vertical bar chart (alternative visualization)
  plot_1.6_bar <- ggplot(fetch_results, aes(x = reorder(category_label, category_order), y = estimate_pct)) +
    geom_col(aes(fill = exceeds_sphere), width = 0.7) +
    geom_errorbar(aes(ymin = ci_lower_pct, ymax = ci_upper_pct),
                  width = 0.3, linewidth = 0.5, color = "#888888") +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)),
              vjust = -0.5, size = 3.5, fontface = "bold") +
    scale_fill_manual(
      values = c("FALSE" = "#009999", "TRUE" = "#e36159"),
      labels = c("FALSE" = "Meets Sphere Standard", "TRUE" = "Exceeds 30 minutes"),
      name = NULL
    ) +
    labs(
      title = "Indicator 1.6: Time to Fetch Water (Round Trip)",
      subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)"),
      x = "Fetch Time Category",
      y = "Percentage of Households",
      caption = "Red: Exceeds Sphere Standard (>30 minutes)\nError bars: 95% confidence intervals"
    ) +
    scale_y_continuous(
      expand = expansion(mult = c(0, 0.15)),
      labels = scales::label_percent(scale = 1)
    ) +
    theme_minimal(base_size = 12) +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      plot.subtitle = element_text(color = "grey40", size = 11),
      panel.grid.major.x = element_blank(),
      panel.grid.minor = element_blank(),
      axis.text.x = element_text(angle = 45, hjust = 1, size = 10),
      axis.text.y = element_text(size = 10),
      legend.position = "bottom"
    )

  ggsave(here("output", "plots", "water_indicator_1.6_bar.png"),
         plot = plot_1.6_bar, width = 10, height = 6, dpi = 300, bg = "white")

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
        str_detect(hh_wq_1_3_2_frc_test_result, "0\\.5.*1\\.0") ~ "0.5-1.0 mg/l (TARGET)",
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
        frc_clean == "0.5-1.0 mg/l (TARGET)" ~ 4,
        frc_clean == ">1.0 mg/l" ~ 5
      )
    ) %>%
    arrange(frc_order) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      in_target = str_detect(frc_clean, "TARGET"),
      fill_color = if_else(in_target, "#009999", "#e36159")
    )

  pct_in_target <- results_1.9 %>% filter(in_target) %>% pull(estimate_pct) %>% sum()

  plot_1.9 <- ggplot(results_1.9, aes(x = estimate_pct, y = "FRC Level",
                                      fill = fill_color)) +
    geom_col(position = "stack", color = "white", linewidth = 1.5) +
    geom_text(aes(label = sprintf("%s\n%d%%", frc_clean, estimate_pct)),
              position = position_stack(vjust = 0.5),
              color = "white", fontface = "bold", size = 3) +
    scale_fill_identity() +
    labs(
      title = "Indicator 1.9: Free Residual Chlorine (FRC) Levels",
      subtitle = glue("Overall Tawila-wide estimate (n={sum(results_1.9$n_unweighted)} households tested)\nTarget range (0.2-1.0 mg/l): {round(pct_in_target)}%"),
      x = "Percentage of Households",
      y = NULL,
      caption = "Teal: Sphere Standard target range (0.2-1.0 mg/l) | Red: Outside target range"
    ) +
    scale_x_continuous(expand = c(0, 0)) +
    theme_minimal(base_size = 12)

  ggsave(here("output", "plots", "water_indicator_1.9.png"),
         plot = plot_1.9, width = 10, height = 4, dpi = 300, bg = "white")

  # Create donut chart (alternative visualization)
  donut_data <- results_1.9 %>%
    arrange(frc_order) %>%
    mutate(
      fraction = estimate_pct / 100,
      ymax = cumsum(fraction),
      ymin = c(0, head(ymax, n = -1)),
      label_position = (ymax + ymin) / 2,
      label_text = sprintf("%s\n%d%%", str_replace(frc_clean, " \\(TARGET\\)", ""), estimate_pct)
    )

  plot_1.9_donut <- ggplot(donut_data, aes(ymax = ymax, ymin = ymin, xmax = 4, xmin = 2, fill = fill_color)) +
    geom_rect(color = "white", linewidth = 2) +
    geom_text(aes(x = 3, y = label_position, label = label_text),
              color = "white", fontface = "bold", size = 3.5) +
    annotate("text", x = 0, y = 0,
             label = sprintf("TARGET\n%d%%\nin range", round(pct_in_target)),
             color = "#009999", fontface = "bold", size = 5) +
    coord_polar(theta = "y") +
    xlim(c(0, 4)) +
    scale_fill_identity() +
    labs(
      title = "Indicator 1.9: Free Residual Chlorine (FRC) Levels",
      subtitle = glue("Overall Tawila-wide estimate (n={sum(results_1.9$n_unweighted)} households tested)")
    ) +
    theme_void() +
    theme(
      plot.title = element_text(hjust = 0.5, face = "bold", size = 14),
      plot.subtitle = element_text(hjust = 0.5, size = 10, margin = margin(b = 10))
    )

  ggsave(here("output", "plots", "water_indicator_1.9_donut.png"),
         plot = plot_1.9_donut, width = 8, height = 8, dpi = 300, bg = "white")

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
  "1.2 Sufficiency (Drinking)" = indicator_1.2,
  "1.2.1 Sufficiency (Domestic)" = indicator_1.2.1,
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

# ================================================================================
# SECTION 7: SURVEY-WEIGHTED ANALYSIS - SANITATION INDICATORS
# ================================================================================
# Purpose: Calculate survey-weighted estimates for Sanitation indicators (2.1-3.0)
# Output: Excel file with 10 indicator sheets and 12 PNG plots
# ================================================================================

message("\n=== Processing Sanitation Indicators ===\n")

# ---- Data Preparation for Sanitation Analysis ----

# Convert sanitation boolean columns to numeric
wash_data <- convert_boolean_columns(wash_data, c(
  "hh_s_",
  "if_yes_select_multiple_",
  "hh_swm_"
))

# Recreate survey design with updated data
survey_design <- create_survey_design(wash_data)

# ---- Indicator 2.1: Sanitation Facility Type ----

indicator_2.1 <- tryCatch({

  facility_cols <- names(wash_data)[str_detect(names(wash_data), "^hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_")] %>%
    setdiff(c("hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use",
              "hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_dont_know",
              "hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_other_specify"))

  facility_results <- map_dfr(facility_cols, function(col) {
    survey_design %>%
      summarise(
        facility_type = col,
        estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100,
        n_unweighted = unweighted(sum(coalesce(!!sym(col), 0) == 1))
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      facility_label = str_remove(facility_type, "hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use_") %>%
        str_replace_all("_", " ") %>%
        str_to_sentence() %>%
        str_wrap(width = 50)
    ) %>%
    arrange(desc(estimate_pct))

  plot_2.1 <- create_bar_plot(
    data = facility_results,
    x_var = estimate_pct,
    y_var = facility_label,
    title = "Indicator 2.1: Sanitation Facility Type",
    subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nMulti-select question - percentages may sum >100%"),
    label_position = "outside"
  )

  ggsave(here("output", "plots", "sanitation_indicator_2.1.png"),
         plot = plot_2.1, width = 10, height = 8, dpi = 300, bg = "white")

  message("  [OK] Indicator 2.1: Sanitation Facility Type")

  facility_results %>%
    select(facility_type = facility_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 2.1: ", e$message)
  return(NULL)
})

# ---- Indicator 2.2: Sanitation Facility Sharing ----

indicator_2.2 <- tryCatch({

  sharing_data <- wash_data %>%
    mutate(
      sharing_response = hh_s_2_1_1_if_applicable_do_you_share_this_sanitation_facility_with_other_households_if_yes_how_many_households_use_this_sanitation_facility_latrine_toilet,
      sharing_count = as.numeric(if_yes_number_of_hh),
      sharing_category = case_when(
        sharing_response == "No" | sharing_count == 1 ~ "No sharing (private)",
        sharing_count >= 2 & sharing_count <= 5 ~ "2-5 households",
        sharing_count >= 6 & sharing_count <= 10 ~ "6-10 households",
        sharing_count >= 11 & sharing_count <= 20 ~ "11-20 households",
        sharing_count > 20 ~ ">20 households",
        TRUE ~ NA_character_
      )
    )

  survey_design_sharing <- sharing_data %>%
    as_survey_design(
      strata = camp_name,
      ids = pseudo_cluster,
      weights = weight,
      nest = TRUE
    )

  results_2.2 <- survey_design_sharing %>%
    group_by(sharing_category) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      .groups = "drop"
    ) %>%
    filter(!is.na(sharing_category)) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(sharing_category = factor(sharing_category, levels = c("No sharing (private)", "2-5 households", "6-10 households", "11-20 households", ">20 households"))) %>%
    arrange(sharing_category)

  plot_2.2 <- ggplot(results_2.2, aes(x = estimate_pct, y = sharing_category, fill = sharing_category)) +
    geom_col(width = 0.7) +
    geom_errorbar(aes(xmin = ci_lower_pct, xmax = ci_upper_pct),
                  width = 0.3, linewidth = 0.5, color = "#888888") +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)),
              hjust = -0.2, size = 3.5) +
    scale_fill_manual(values = c(
      "No sharing (private)" = "#009999",
      "2-5 households" = "#009999",
      "6-10 households" = "#009999",
      "11-20 households" = "#e36159",
      ">20 households" = "#e36159"
    )) +
    labs(title = "Indicator 2.2: Sanitation Facility Sharing",
         subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nSphere standard: max 1 toilet per 20 people"),
         x = "Percentage of Households",
         y = NULL) +
    scale_x_continuous(
      expand = expansion(mult = c(0, 0.15)),
      labels = scales::label_percent(scale = 1)
    ) +
    theme_minimal(base_size = 12) +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      plot.subtitle = element_text(color = "grey40", size = 11),
      panel.grid.major.y = element_blank(),
      panel.grid.minor = element_blank(),
      axis.text = element_text(size = 10),
      legend.position = "none"
    )

  ggsave(here("output", "plots", "sanitation_indicator_2.2.png"),
         plot = plot_2.2, width = 10, height = 4, dpi = 300, bg = "white")

  message("  [OK] Indicator 2.2: Sanitation Facility Sharing")

  results_2.2 %>%
    select(sharing_category, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 2.2: ", e$message)
  return(NULL)
})

# ---- Indicator 2.3: Sanitation Problems ----

indicator_2.3 <- tryCatch({

  problem_cols <- names(wash_data)[str_detect(names(wash_data), "^if_yes_select_multiple_")] %>%
    setdiff(c("if_yes_select_multiple", "if_yes_select_multiple_dont_know", "if_yes_select_multiple_other_specify"))

  problem_results <- map_dfr(problem_cols, function(col) {
    survey_design %>%
      summarise(
        problem_type = col,
        estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100,
        n_unweighted = unweighted(sum(coalesce(!!sym(col), 0) == 1))
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      problem_label = str_remove(problem_type, "if_yes_select_multiple_") %>%
        str_replace_all("_", " ") %>%
        str_to_sentence() %>%
        {if_else(. == "No", "No problems", .)} %>%
        str_wrap(width = 50)
    ) %>%
    arrange(desc(estimate_pct))

  plot_2.3 <- create_bar_plot(
    data = problem_results,
    x_var = estimate_pct,
    y_var = problem_label,
    title = "Indicator 2.3: Sanitation Problems",
    subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nAll responses shown - percentages may sum >100%"),
    label_position = "outside"
  )

  ggsave(here("output", "plots", "sanitation_indicator_2.3.png"),
         plot = plot_2.3, width = 10, height = 8, dpi = 300, bg = "white")

  message("  [OK] Indicator 2.3: Sanitation Problems")

  problem_results %>%
    select(problem_type = problem_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 2.3: ", e$message)
  return(NULL)
})

# ---- Indicator 2.4: Sanitation Coping Mechanisms ----

indicator_2.4 <- tryCatch({

  coping_cols <- names(wash_data)[str_detect(names(wash_data), "^hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets_")] %>%
    setdiff(c("hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets",
              "hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets_dont_know",
              "hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets_other_specify"))

  coping_results <- map_dfr(coping_cols, function(col) {
    survey_design %>%
      summarise(
        coping_mechanism = col,
        estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100,
        n_unweighted = unweighted(sum(coalesce(!!sym(col), 0) == 1))
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      coping_label = str_remove(coping_mechanism, "hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets_") %>%
        str_replace_all("_", " ") %>%
        str_to_sentence() %>%
        str_wrap(width = 50)
    ) %>%
    arrange(desc(estimate_pct))

  plot_2.4 <- create_bar_plot(
    data = coping_results,
    x_var = estimate_pct,
    y_var = coping_label,
    title = "Indicator 2.4: Sanitation Coping Mechanisms",
    subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nMulti-select question - percentages may sum >100%"),
    label_position = "outside"
  )

  ggsave(here("output", "plots", "sanitation_indicator_2.4.png"),
         plot = plot_2.4, width = 10, height = 8, dpi = 300, bg = "white")

  message("  [OK] Indicator 2.4: Sanitation Coping Mechanisms")

  coping_results %>%
    select(coping_mechanism = coping_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 2.4: ", e$message)
  return(NULL)
})

# ---- Indicator 2.5: Feeling Unsafe at Sanitation Facilities ----

indicator_2.5 <- tryCatch({

  # Check if source field has any non-NA values
  source_field <- survey_design$variables$hh_s_2_5_do_you_feel_unsafe_at_the_sanitation_facilities_you_use_most_often_because_you_fear_being_harmed_or_assaulted_by_someone
  if (all(is.na(source_field))) {
    message("  [NO DATA] Indicator 2.5: All responses are NA - field may not exist in this form version")
    return(NULL)
  }

  results_2.5 <- survey_design %>%
    group_by(gender = gender_of_the_respondent) %>%
    summarise(
      unsafe_pct = survey_mean(hh_s_2_5_do_you_feel_unsafe_at_the_sanitation_facilities_you_use_most_often_because_you_fear_being_harmed_or_assaulted_by_someone == "Yes", vartype = "ci", na.rm = TRUE) * 100,
      n_unweighted = unweighted(n()),
      n_effective = n(),
      .groups = "drop"
    ) %>%
    filter(!is.na(gender)) %>%
    rename(ci_lower_pct = unsafe_pct_low, ci_upper_pct = unsafe_pct_upp) %>%
    mutate(across(c(unsafe_pct, ci_lower_pct, ci_upper_pct), round))

  plot_2.5 <- ggplot(results_2.5, aes(x = gender, y = unsafe_pct, fill = gender)) +
    geom_col(width = 0.6) +
    geom_errorbar(aes(ymin = ci_lower_pct, ymax = ci_upper_pct),
                  width = 0.2, linewidth = 0.5, color = "#888888") +
    geom_text(aes(label = sprintf("%d%%", unsafe_pct)),
              vjust = -0.5, size = 4) +
    scale_fill_manual(values = c("Female" = "#e36159", "Male" = "#e36159")) +
    labs(title = "Indicator 2.5: Feeling Unsafe at Sanitation Facilities",
         subtitle = glue("By respondent gender (n={nrow(wash_data)} households)"),
         x = "Respondent Gender",
         y = "Percentage Reporting Feeling Unsafe") +
    scale_y_continuous(
      expand = expansion(mult = c(0, 0.15)),
      labels = scales::label_percent(scale = 1)
    ) +
    theme_minimal(base_size = 12) +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      plot.subtitle = element_text(color = "grey40", size = 11),
      panel.grid.major.x = element_blank(),
      panel.grid.minor = element_blank(),
      legend.position = "none",
      axis.text = element_text(size = 10)
    )

  ggsave(here("output", "plots", "sanitation_indicator_2.5.png"),
         plot = plot_2.5, width = 8, height = 6, dpi = 300, bg = "white")

  message("  [OK] Indicator 2.5: Feeling Unsafe at Sanitation Facilities")

  results_2.5 %>%
    select(gender, estimate_pct = unsafe_pct, ci_lower_pct, ci_upper_pct, n_unweighted, n_effective)

}, error = function(e) {
  message("  [ERROR] Indicator 2.5: ", e$message)
  return(NULL)
})

# ---- Indicator 2.6: Observed Open Defecation ----

# 2.6a: Overall observation prevalence
indicator_2.6a <- tryCatch({

  # Check if source field has any non-NA values
  source_field <- survey_design$variables$hh_s_2_6_has_anyone_in_your_household_observed_open_defecation_in_the_area
  if (all(is.na(source_field))) {
    message("  [NO DATA] Indicator 2.6a: All responses are NA - field may not exist in this form version")
    return(NULL)
  }

  results_2.6a <- survey_design %>%
    group_by(observed = hh_s_2_6_has_anyone_in_your_household_observed_open_defecation_in_the_area) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      .groups = "drop"
    ) %>%
    filter(!is.na(observed)) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))

  plot_2.6a <- ggplot(results_2.6a, aes(x = estimate_pct, y = observed)) +
    geom_col(aes(fill = observed), width = 0.7) +
    geom_errorbar(aes(xmin = ci_lower_pct, xmax = ci_upper_pct),
                  width = 0.3, linewidth = 0.5, color = "#888888") +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)),
              hjust = -0.2, size = 4) +
    labs(title = "Indicator 2.6a: Observed Open Defecation",
         subtitle = glue("Overall prevalence (n={nrow(wash_data)} households)"),
         x = "Percentage of Households",
         y = NULL) +
    scale_fill_manual(
      values = c("Yes" = "#e36159", "No" = "#009999"),
      guide = "none"
    ) +
    scale_x_continuous(
      expand = expansion(mult = c(0, 0.15)),
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

  ggsave(here("output", "plots", "sanitation_indicator_2.6a.png"),
         plot = plot_2.6a, width = 8, height = 3, dpi = 300, bg = "white")

  message("  [OK] Indicator 2.6a: Observed Open Defecation - Overall")

  results_2.6a %>%
    select(observation_response = observed, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 2.6a: ", e$message)
  return(NULL)
})

# 2.6b: Who was observed
indicator_2.6b <- tryCatch({

  who_cols <- names(wash_data)[str_detect(names(wash_data), "^hh_s_2_6_1_if_yes_a_please_specify_who_was_observed_practicing_open_defecation_")]

  who_results <- map_dfr(who_cols, function(col) {
    survey_design %>%
      summarise(
        age_group = col,
        estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100,
        n_unweighted = unweighted(sum(coalesce(!!sym(col), 0) == 1))
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      age_label = str_remove(age_group, "hh_s_2_6_1_if_yes_a_please_specify_who_was_observed_practicing_open_defecation_") %>%
        str_replace_all("_", " ") %>%
        str_to_sentence() %>%
        {if_else(. == "No", "None observed", .)} %>%
        str_wrap(width = 50)
    ) %>%
    arrange(desc(estimate_pct))

  plot_2.6b <- create_bar_plot(
    data = who_results,
    x_var = estimate_pct,
    y_var = age_label,
    title = "Indicator 2.6b: Who Was Observed Practicing Open Defecation",
    subtitle = glue("By age group (n={nrow(wash_data)} households)\nAll responses shown - percentages may sum >100%"),
    label_position = "outside"
  )

  ggsave(here("output", "plots", "sanitation_indicator_2.6b.png"),
         plot = plot_2.6b, width = 10, height = 6, dpi = 300, bg = "white")

  message("  [OK] Indicator 2.6b: Observed Open Defecation - Who")

  who_results %>%
    select(age_group = age_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 2.6b: ", e$message)
  return(NULL)
})

# 2.6c: When observed
indicator_2.6c <- tryCatch({

  when_cols <- names(wash_data)[str_detect(names(wash_data), "^hh_s_2_6_1_1_if_yes_b_when_was_open_defecation_most_often_observed_")]

  when_results <- map_dfr(when_cols, function(col) {
    survey_design %>%
      summarise(
        time_period = col,
        estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100,
        n_unweighted = unweighted(sum(coalesce(!!sym(col), 0) == 1))
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      time_label = str_remove(time_period, "hh_s_2_6_1_1_if_yes_b_when_was_open_defecation_most_often_observed_") %>%
        str_replace_all("_", " ") %>%
        str_to_sentence() %>%
        {if_else(. == "No", "None observed", .)} %>%
        str_wrap(width = 50)
    ) %>%
    arrange(desc(estimate_pct))

  plot_2.6c <- create_bar_plot(
    data = when_results,
    x_var = estimate_pct,
    y_var = time_label,
    title = "Indicator 2.6c: When Was Open Defecation Observed",
    subtitle = glue("By time of day (n={nrow(wash_data)} households)\nAll responses shown - percentages may sum >100%"),
    label_position = "outside"
  )

  ggsave(here("output", "plots", "sanitation_indicator_2.6c.png"),
         plot = plot_2.6c, width = 10, height = 6, dpi = 300, bg = "white")

  message("  [OK] Indicator 2.6c: Observed Open Defecation - When")

  when_results %>%
    select(time_period = time_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 2.6c: ", e$message)
  return(NULL)
})

# ---- Indicator 2.7: Children <5 Defecation Practices ----

indicator_2.7 <- tryCatch({

  practice_cols <- names(wash_data)[str_detect(names(wash_data), "^hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate_")] %>%
    setdiff(c("hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate",
              "hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate_don_t_know",
              "hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate_other_specify"))

  practice_results <- map_dfr(practice_cols, function(col) {
    survey_design %>%
      summarise(
        practice_type = col,
        estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100,
        n_unweighted = unweighted(sum(coalesce(!!sym(col), 0) == 1))
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      practice_label = str_remove(practice_type, "hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate_") %>%
        str_replace_all("_", " ") %>%
        str_to_sentence() %>%
        str_wrap(width = 50)
    ) %>%
    arrange(desc(estimate_pct)) %>%
    mutate(
      fill_color = if_else(str_detect(practice_label, "(?i)open defec"), "#e36159", "#009999")
    )

  plot_2.7 <- ggplot(practice_results, aes(x = estimate_pct, y = reorder(practice_label, estimate_pct))) +
    geom_col(aes(fill = fill_color), width = 0.7) +
    geom_errorbar(aes(xmin = ci_lower_pct, xmax = ci_upper_pct),
                  width = 0.3, linewidth = 0.5, color = "#888888") +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)),
              hjust = -0.2, size = 3.5) +
    scale_fill_identity() +
    labs(
      title = "Indicator 2.7: Children <5 Defecation Practices",
      subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nMulti-select question - percentages may sum >100%"),
      x = "Percentage of Households",
      y = NULL
    ) +
    scale_x_continuous(
      expand = expansion(mult = c(0, 0.15)),
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

  ggsave(here("output", "plots", "sanitation_indicator_2.7.png"),
         plot = plot_2.7, width = 10, height = 6, dpi = 300, bg = "white")

  message("  [OK] Indicator 2.7: Children <5 Defecation Practices")

  practice_results %>%
    select(practice_type = practice_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 2.7: ", e$message)
  return(NULL)
})

# ---- Indicator 2.8: Damaged/Non-functional Latrines ----

indicator_2.8 <- tryCatch({

  # Check if source field has any non-NA values
  source_field <- survey_design$variables$hh_s_2_3_in_the_last_30_days_was_the_latrine_you_used_damaged_non_functional_or_full
  if (all(is.na(source_field))) {
    message("  [NO DATA] Indicator 2.8: All responses are NA - field may not exist in this form version")
    return(NULL)
  }

  results_2.8 <- survey_design %>%
    group_by(status = hh_s_2_3_in_the_last_30_days_was_the_latrine_you_used_damaged_non_functional_or_full) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      .groups = "drop"
    ) %>%
    filter(!is.na(status)) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      fill_color = if_else(status == "Yes", "#e36159", "#009999")
    )

  plot_2.8 <- ggplot(results_2.8, aes(x = estimate_pct, y = status)) +
    geom_col(aes(fill = fill_color), width = 0.7) +
    scale_fill_identity() +
    geom_errorbar(aes(xmin = ci_lower_pct, xmax = ci_upper_pct),
                  width = 0.3, linewidth = 0.5, color = "#888888") +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)),
              hjust = -0.2, size = 4) +
    labs(title = "Indicator 2.8: Damaged/Non-functional Latrines",
         subtitle = glue("Last 30 days (n={nrow(wash_data)} households)"),
         x = "Percentage of Households",
         y = NULL) +
    scale_x_continuous(
      expand = expansion(mult = c(0, 0.15)),
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

  ggsave(here("output", "plots", "sanitation_indicator_2.8.png"),
         plot = plot_2.8, width = 8, height = 3, dpi = 300, bg = "white")

  message("  [OK] Indicator 2.8: Damaged/Non-functional Latrines")

  results_2.8 %>%
    select(latrine_status = status, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 2.8: ", e$message)
  return(NULL)
})

# ---- Indicator 2.9: Visible Human Feces ----

indicator_2.9 <- tryCatch({

  # Check if source field has any non-NA values
  source_field <- survey_design$variables$hh_s_2_9_was_there_visible_traces_of_human_faeces_in_the_vicinity_10_meters_or_less_of_your_accommodation_in_the_last_30_days
  if (all(is.na(source_field))) {
    message("  [NO DATA] Indicator 2.9: All responses are NA - field may not exist in this form version")
    return(NULL)
  }

  # Response categories: "Never visible", "Sometime visible", "Frequently visible", "Don't know"
  results_2.9 <- survey_design %>%
    group_by(frequency = hh_s_2_9_was_there_visible_traces_of_human_faeces_in_the_vicinity_10_meters_or_less_of_your_accommodation_in_the_last_30_days) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      .groups = "drop"
    ) %>%
    filter(!is.na(frequency)) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))

  # Order categories logically
  category_order <- c("Never visible", "Sometime visible", "Frequently visible", "Don't know")
  results_2.9 <- results_2.9 %>%
    mutate(
      frequency = factor(frequency, levels = rev(category_order)),
      fill_color = if_else(frequency %in% c("Sometime visible", "Frequently visible"), "#e36159", "#009999")
    )

  # Calculate combined "any visible" percentage for subtitle
  any_visible_pct <- results_2.9 %>%
    filter(frequency %in% c("Sometime visible", "Frequently visible")) %>%
    summarise(pct = sum(estimate_pct)) %>%
    pull(pct)

  plot_2.9 <- ggplot(results_2.9, aes(x = estimate_pct, y = frequency)) +
    geom_col(aes(fill = fill_color), width = 0.7) +
    scale_fill_identity() +
    geom_errorbar(aes(xmin = ci_lower_pct, xmax = ci_upper_pct),
                  width = 0.3, linewidth = 0.5, color = "#888888") +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)),
              hjust = -0.2, size = 4) +
    labs(title = "Indicator 2.9: Visible Human Feces Near Accommodation",
         subtitle = glue("Last 30 days (n={nrow(wash_data)} households) | Any visible: {any_visible_pct}%"),
         x = "Percentage of Households",
         y = NULL) +
    scale_x_continuous(
      expand = expansion(mult = c(0, 0.15)),
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

  ggsave(here("output", "plots", "sanitation_indicator_2.9.png"),
         plot = plot_2.9, width = 8, height = 4, dpi = 300, bg = "white")

  message("  [OK] Indicator 2.9: Visible Human Feces")

  results_2.9 %>%
    mutate(frequency = as.character(frequency)) %>%
    select(frequency, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 2.9: ", e$message)
  return(NULL)
})

# ---- Indicator 3.0: Solid Waste Disposal ----

indicator_3.0 <- tryCatch({

  waste_cols <- names(wash_data)[str_detect(names(wash_data), "^hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage_")] %>%
    setdiff(c("hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage",
              "hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage_dont_know",
              "hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage_other_specify"))

  waste_results <- map_dfr(waste_cols, function(col) {
    survey_design %>%
      summarise(
        disposal_method = col,
        estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100,
        n_unweighted = unweighted(sum(coalesce(!!sym(col), 0) == 1))
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      disposal_label = str_remove(disposal_method, "hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage_") %>%
        str_replace_all("_", " ") %>%
        str_to_sentence() %>%
        str_wrap(width = 50)
    ) %>%
    arrange(desc(estimate_pct))

  plot_3.0 <- create_bar_plot(
    data = waste_results,
    x_var = estimate_pct,
    y_var = disposal_label,
    title = "Indicator 3.0: Solid Waste Disposal Methods",
    subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nMulti-select question - percentages may sum >100%"),
    label_position = "outside"
  )

  ggsave(here("output", "plots", "sanitation_indicator_3.0.png"),
         plot = plot_3.0, width = 10, height = 6, dpi = 300, bg = "white")

  message("  [OK] Indicator 3.0: Solid Waste Disposal")

  waste_results %>%
    select(disposal_method = disposal_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 3.0: ", e$message)
  return(NULL)
})

# ---- Export Sanitation Results to Excel ----

message("\n=== Exporting Sanitation results to Excel ===")

sanitation_sheets <- list(
  "2.1 Facility Type" = indicator_2.1,
  "2.2 Facility Sharing" = indicator_2.2,
  "2.3 Problems" = indicator_2.3,
  "2.4 Coping Mechanisms" = indicator_2.4,
  "2.5 Feeling Unsafe" = indicator_2.5,
  "2.6a OD Observed" = indicator_2.6a,
  "2.6b OD Who" = indicator_2.6b,
  "2.6c OD When" = indicator_2.6c,
  "2.7 Children U5 Practice" = indicator_2.7,
  "2.8 Damaged Latrines" = indicator_2.8,
  "2.9 Visible Feces" = indicator_2.9,
  "3.0 Waste Disposal" = indicator_3.0
)

sanitation_sheets <- sanitation_sheets %>% discard(is.null)

output_file_san <- here("output", "wash_survey_sanitation_indicators.xlsx")
write_xlsx(sanitation_sheets, path = output_file_san)

message(glue("  Saved: {basename(output_file_san)} ({length(sanitation_sheets)} sheets)"))
message(glue("  Plots: output/plots/sanitation_indicator_*.png ({length(sanitation_sheets)} files)\n"))

# ================================================================================
# SECTION 8: SURVEY-WEIGHTED ANALYSIS - HYGIENE INDICATORS
# ================================================================================
# Purpose: Calculate survey-weighted estimates for Hygiene indicators (4.1-4.11)
# Output: Excel file with 9 indicator sheets and 9 PNG plots
# ================================================================================

message("\n=== Processing Table 2 (continued): Hygiene Indicators ===\n")

# Convert hygiene boolean columns to numeric
wash_data <- convert_boolean_columns(wash_data, c(
  "hh_h_",
  "if_yes_which_ones_",
  "during_your_last_"
))

# Recreate survey design with updated data
survey_design <- create_survey_design(wash_data)

# ---- Indicator 4.1: Hygiene NFI Problems ----

indicator_4.1 <- tryCatch({

  problem_cols <- names(wash_data)[str_detect(names(wash_data), "^if_yes_which_ones_")] %>%
    setdiff(c("if_yes_which_ones", "if_yes_which_ones_dont_know", "if_yes_which_ones_don_t_know",
              "if_yes_which_ones_other_specify"))

  problem_results <- map_dfr(problem_cols, function(col) {
    survey_design %>%
      summarise(
        problem_type = col,
        estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100,
        n_unweighted = unweighted(sum(coalesce(!!sym(col), 0) == 1))
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      problem_label = str_remove(problem_type, "if_yes_which_ones_") %>%
        str_replace_all("_", " ") %>%
        str_to_sentence() %>%
        {if_else(. == "No", "No problems", .)} %>%
        str_wrap(width = 50)
    ) %>%
    arrange(desc(estimate_pct))

  plot_4.1 <- create_bar_plot(
    data = problem_results,
    x_var = estimate_pct,
    y_var = problem_label,
    title = "Indicator 4.1: Hygiene NFI Problems",
    subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nAll responses shown - percentages may sum >100%"),
    label_position = "outside"
  )

  ggsave(here("output", "plots", "hygiene_indicator_4.1.png"),
         plot = plot_4.1, width = 10, height = 8, dpi = 300, bg = "white")

  message("  [OK] Indicator 4.1: Hygiene NFI Problems")

  problem_results %>%
    select(problem_type = problem_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 4.1: ", e$message)
  return(NULL)
})

# ---- Indicator 4.2: Hygiene NFI Coping Mechanisms ----

indicator_4.2 <- tryCatch({

  coping_cols <- names(wash_data)[str_detect(names(wash_data), "^hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_")] %>%
    setdiff(c("hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items",
              "hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_dont_know",
              "hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_don_t_know",
              "hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_other_specify"))

  coping_results <- map_dfr(coping_cols, function(col) {
    survey_design %>%
      summarise(
        coping_mechanism = col,
        estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100,
        n_unweighted = unweighted(sum(coalesce(!!sym(col), 0) == 1))
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      coping_label = str_remove(coping_mechanism, "hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items_") %>%
        str_replace_all("_", " ") %>%
        str_to_sentence() %>%
        str_wrap(width = 50)
    ) %>%
    arrange(desc(estimate_pct))

  plot_4.2 <- create_bar_plot(
    data = coping_results,
    x_var = estimate_pct,
    y_var = coping_label,
    title = "Indicator 4.2: Hygiene NFI Coping Mechanisms",
    subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nMulti-select question - percentages may sum >100%"),
    label_position = "outside"
  )

  ggsave(here("output", "plots", "hygiene_indicator_4.2.png"),
         plot = plot_4.2, width = 10, height = 8, dpi = 300, bg = "white")

  message("  [OK] Indicator 4.2: Hygiene NFI Coping Mechanisms")

  coping_results %>%
    select(coping_mechanism = coping_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 4.2: ", e$message)
  return(NULL)
})

# ---- Indicator 4.3: Hygiene Spending Categories ----

indicator_4.3 <- tryCatch({

  spending_field <- "hh_h_4_1_1_how_much_did_your_household_spend_on_hygiene_items_soap_shampoo_sanitary_pads_diapers_and_water_containers_in_the_last_30_days"

  results_4.3 <- survey_design %>%
    group_by(spending_category = !!sym(spending_field)) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      .groups = "drop"
    ) %>%
    filter(!is.na(spending_category)) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))

  # Order by spending range (ascending)
  results_4.3 <- results_4.3 %>%
    mutate(
      category_order = case_when(
        str_detect(spending_category, "^0") ~ 1,
        str_detect(spending_category, "10,000 SDG$|10.000") ~ 2,
        str_detect(spending_category, "20,000|20.000") ~ 3,
        str_detect(spending_category, "40,000|40.000") ~ 4,
        str_detect(spending_category, "60,000|60.000") ~ 5,
        str_detect(spending_category, "More|more|>") ~ 6,
        TRUE ~ 7
      ),
      category_label = spending_category
    ) %>%
    arrange(category_order)

  # Teal gradient for hygiene spending
  # Trim to number of categories
  fill_colors <- GWC_TEAL_GRADIENT_5[seq_len(nrow(results_4.3))]

  plot_4.3 <- ggplot(results_4.3, aes(x = estimate_pct, y = "Spending",
                                       fill = factor(category_label, levels = rev(unique(category_label))))) +
    geom_col(position = "stack", color = "white", linewidth = 1.5) +
    geom_text(aes(label = sprintf("%s\n%d%%", category_label, estimate_pct)),
              position = position_stack(vjust = 0.5),
              color = "white", fontface = "bold", size = 3) +
    scale_fill_manual(values = setNames(rev(fill_colors), rev(unique(results_4.3$category_label))),
                      name = "Spending Range") +
    labs(
      title = "Indicator 4.3: Hygiene Spending (Past 30 Days)",
      subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nCategorical ranges in Sudanese Pounds (SDG)"),
      x = "Percentage of Households",
      y = NULL
    ) +
    scale_x_continuous(expand = c(0, 0)) +
    theme_minimal(base_size = 12) +
    theme(legend.position = "none")

  ggsave(here("output", "plots", "hygiene_indicator_4.3.png"),
         plot = plot_4.3, width = 10, height = 4, dpi = 300, bg = "white")

  # Create donut chart (alternative visualization)
  donut_data_4.3 <- results_4.3 %>%
    arrange(category_order) %>%
    mutate(
      fraction = estimate_pct / 100,
      ymax = cumsum(fraction),
      ymin = c(0, head(ymax, n = -1)),
      label_position = (ymax + ymin) / 2,
      label_text = sprintf("%s\n%d%%", category_label, estimate_pct),
      fill_color = fill_colors[seq_len(n())]
    )

  plot_4.3_donut <- ggplot(donut_data_4.3, aes(ymax = ymax, ymin = ymin, xmax = 4, xmin = 2, fill = fill_color)) +
    geom_rect(color = "white", linewidth = 2) +
    geom_text(aes(x = 3, y = label_position, label = label_text),
              color = "white", fontface = "bold", size = 3) +
    coord_polar(theta = "y") +
    xlim(c(0, 4)) +
    scale_fill_identity() +
    labs(
      title = "Indicator 4.3: Hygiene Spending (Past 30 Days)",
      subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)")
    ) +
    theme_void() +
    theme(
      plot.title = element_text(hjust = 0.5, face = "bold", size = 14),
      plot.subtitle = element_text(hjust = 0.5, size = 10, margin = margin(b = 10))
    )

  ggsave(here("output", "plots", "hygiene_indicator_4.3_donut.png"),
         plot = plot_4.3_donut, width = 8, height = 8, dpi = 300, bg = "white")

  message("  [OK] Indicator 4.3: Hygiene Spending Categories")

  results_4.3 %>%
    select(spending_category = category_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 4.3: ", e$message)
  return(NULL)
})

# ---- Indicator 4.4: SKIP (Data Gap) ----
# Barriers to WASH NFI in market not collected as a dedicated question.
# Partial data may exist in 4.1 problem types (market-related barriers).

# ---- Indicator 4.5: Satisfaction with Hygiene NFI Access ----

indicator_4.5 <- tryCatch({

  satisfaction_field <- "hh_h_4_1_2_how_satisfied_is_your_household_with_regards_to_access_to_hygiene_items_soap_feminine_hygiene_products_baby_diapers_toothpaste_brush"

  results_4.5 <- survey_design %>%
    group_by(satisfaction = !!sym(satisfaction_field)) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      .groups = "drop"
    ) %>%
    filter(!is.na(satisfaction)) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))

  # Likert scale ordering (negative to positive)
  likert_order <- c("Very unsatisfied", "Unsatisfied", "Don't know", "Satisfied", "Very satisfied")
  results_4.5 <- results_4.5 %>%
    mutate(satisfaction = factor(satisfaction, levels = likert_order)) %>%
    filter(!is.na(satisfaction)) %>%
    arrange(satisfaction)

  # Diverging color scale (red to teal)
  likert_colors <- c(
    "Very unsatisfied" = as.vector(GWC_LIKERT_5["very_negative"]),
    "Unsatisfied" = as.vector(GWC_LIKERT_5["negative"]),
    "Don't know" = as.vector(GWC_LIKERT_5["neutral"]),
    "Satisfied" = as.vector(GWC_LIKERT_5["positive"]),
    "Very satisfied" = as.vector(GWC_LIKERT_5["very_positive"])
  )

  plot_4.5 <- ggplot(results_4.5, aes(x = estimate_pct, y = "Satisfaction",
                                       fill = satisfaction)) +
    geom_col(position = "stack", color = "white", linewidth = 1.5) +
    geom_text(aes(label = sprintf("%s\n%d%%", satisfaction, estimate_pct)),
              position = position_stack(vjust = 0.5),
              color = "white", fontface = "bold", size = 3) +
    scale_fill_manual(values = likert_colors, name = "Satisfaction Level") +
    labs(
      title = "Indicator 4.5: Satisfaction with Hygiene NFI Access",
      subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)"),
      x = "Percentage of Households",
      y = NULL
    ) +
    scale_x_continuous(expand = c(0, 0)) +
    theme_minimal(base_size = 12) +
    theme(legend.position = "none")

  ggsave(here("output", "plots", "hygiene_indicator_4.5.png"),
         plot = plot_4.5, width = 10, height = 4, dpi = 300, bg = "white")

  # Create donut chart (alternative visualization)
  donut_data_4.5 <- results_4.5 %>%
    arrange(satisfaction) %>%
    mutate(
      fraction = estimate_pct / 100,
      ymax = cumsum(fraction),
      ymin = c(0, head(ymax, n = -1)),
      label_position = (ymax + ymin) / 2,
      label_text = sprintf("%s\n%d%%", satisfaction, estimate_pct),
      fill_color = likert_colors[as.character(satisfaction)]
    )

  plot_4.5_donut <- ggplot(donut_data_4.5, aes(ymax = ymax, ymin = ymin, xmax = 4, xmin = 2, fill = fill_color)) +
    geom_rect(color = "white", linewidth = 2) +
    geom_text(aes(x = 3, y = label_position, label = label_text),
              color = "white", fontface = "bold", size = 3) +
    coord_polar(theta = "y") +
    xlim(c(0, 4)) +
    scale_fill_identity() +
    labs(
      title = "Indicator 4.5: Satisfaction with Hygiene NFI Access",
      subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)")
    ) +
    theme_void() +
    theme(
      plot.title = element_text(hjust = 0.5, face = "bold", size = 14),
      plot.subtitle = element_text(hjust = 0.5, size = 10, margin = margin(b = 10))
    )

  ggsave(here("output", "plots", "hygiene_indicator_4.5_donut.png"),
         plot = plot_4.5_donut, width = 8, height = 8, dpi = 300, bg = "white")

  message("  [OK] Indicator 4.5: Satisfaction with Hygiene NFI Access")

  results_4.5 %>%
    mutate(satisfaction = as.character(satisfaction)) %>%
    select(satisfaction, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 4.5: ", e$message)
  return(NULL)
})

# ---- Indicator 4.6: Handwashing Device Access ----

indicator_4.6 <- tryCatch({

  device_field <- "hh_h_4_2_what_kind_of_handwashing_device_mechanism_do_your_household_members_usually_use_to_wash_their_hands_ask_to_see_the_handwashing_device"
  supply_field <- "hh_h_4_2_1_do_you_have_enough_water_and_soap_for_handwashing"

  # (a) Device type distribution
  results_device <- survey_design %>%
    group_by(device_type = !!sym(device_field)) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      .groups = "drop"
    ) %>%
    filter(!is.na(device_type)) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    arrange(desc(estimate_pct))

  # Clean device labels
  results_device <- results_device %>%
    mutate(device_label = str_replace_all(device_type, "_", " ") %>%
             str_to_sentence() %>%
             str_wrap(width = 40))

  plot_4.6 <- create_bar_plot(
    data = results_device,
    x_var = estimate_pct,
    y_var = device_label,
    title = "Indicator 4.6: Handwashing Device Type",
    subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)"),
    label_position = "outside"
  )

  ggsave(here("output", "plots", "hygiene_indicator_4.6.png"),
         plot = plot_4.6, width = 10, height = 6, dpi = 300, bg = "white")

  message("  [OK] Indicator 4.6: Handwashing Device Access")

  results_device %>%
    select(device_type = device_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 4.6: ", e$message)
  return(NULL)
})

# ---- Indicators 4.7 & 4.8: Water and Soap at Handwashing (Combined) ----

indicator_4.7_4.8 <- tryCatch({

  supply_field <- "hh_h_4_2_1_do_you_have_enough_water_and_soap_for_handwashing"

  results_4.7_4.8 <- survey_design %>%
    group_by(water_soap = !!sym(supply_field)) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      .groups = "drop"
    ) %>%
    filter(!is.na(water_soap)) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      fill_color = if_else(water_soap == "No", "#e36159", "#009999")
    )

  plot_4.7_4.8 <- ggplot(results_4.7_4.8, aes(x = estimate_pct, y = water_soap)) +
    geom_col(aes(fill = fill_color), width = 0.6) +
    scale_fill_identity() +
    geom_errorbar(aes(xmin = ci_lower_pct, xmax = ci_upper_pct),
                  width = 0.2, linewidth = 0.5, color = "#888888") +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)),
              hjust = -0.2, size = 4) +
    labs(title = "Indicators 4.7-4.8: Water and Soap at Handwashing",
         subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nNote: survey asks about water AND soap combined; cannot separate"),
         x = "Percentage of Households",
         y = NULL) +
    scale_x_continuous(
      expand = expansion(mult = c(0, 0.15)),
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

  ggsave(here("output", "plots", "hygiene_indicator_4.7_4.8.png"),
         plot = plot_4.7_4.8, width = 8, height = 4, dpi = 300, bg = "white")

  message("  [OK] Indicators 4.7-4.8: Water and Soap at Handwashing")

  results_4.7_4.8 %>%
    select(water_soap, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicators 4.7-4.8: ", e$message)
  return(NULL)
})

# ---- Indicator 4.9.1: Soap at Home ----

indicator_4.9.1 <- tryCatch({

  soap_field <- "hh_h_4_2_2_do_you_have_enough_soap_at_household_for_all_purposes"

  results_4.9.1 <- survey_design %>%
    group_by(soap_at_home = !!sym(soap_field)) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      .groups = "drop"
    ) %>%
    filter(!is.na(soap_at_home)) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      fill_color = if_else(soap_at_home == "No", "#e36159", "#009999")
    )

  plot_4.9.1 <- ggplot(results_4.9.1, aes(x = estimate_pct, y = soap_at_home)) +
    geom_col(aes(fill = fill_color), width = 0.6) +
    scale_fill_identity() +
    geom_errorbar(aes(xmin = ci_lower_pct, xmax = ci_upper_pct),
                  width = 0.2, linewidth = 0.5, color = "#888888") +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)),
              hjust = -0.2, size = 4) +
    labs(title = "Indicator 4.9.1: Soap at Home",
         subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nDo you have enough soap at household for all purposes?"),
         x = "Percentage of Households",
         y = NULL) +
    scale_x_continuous(
      expand = expansion(mult = c(0, 0.15)),
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

  ggsave(here("output", "plots", "hygiene_indicator_4.9.1.png"),
         plot = plot_4.9.1, width = 8, height = 4, dpi = 300, bg = "white")

  message("  [OK] Indicator 4.9.1: Soap at Home")

  results_4.9.1 %>%
    select(soap_at_home, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 4.9.1: ", e$message)
  return(NULL)
})

# ---- Indicator 4.9.2: Barriers to Soap Access ----

indicator_4.9.2 <- tryCatch({

  barrier_cols <- names(wash_data)[str_detect(names(wash_data), "^hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_")] %>%
    setdiff(c("hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap",
              "hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_dont_know",
              "hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_don_t_know",
              "hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_other_specify"))

  # Denominator: only HH without sufficient soap (4.9.1 = No)
  soap_field <- "hh_h_4_2_2_do_you_have_enough_soap_at_household_for_all_purposes"
  no_soap_data <- wash_data %>%
    filter(!!sym(soap_field) == "No")

  no_soap_design <- no_soap_data %>%
    as_survey_design(
      strata = camp_name,
      ids = pseudo_cluster,
      weights = weight,
      nest = TRUE
    )

  barrier_results <- map_dfr(barrier_cols, function(col) {
    no_soap_design %>%
      summarise(
        barrier_type = col,
        estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100,
        n_unweighted = unweighted(sum(coalesce(!!sym(col), 0) == 1))
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      barrier_label = str_remove(barrier_type, "hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap_") %>%
        str_replace_all("_", " ") %>%
        str_to_sentence() %>%
        {if_else(. == "Yes", "Has soap (yes)", .)} %>%
        str_wrap(width = 50)
    ) %>%
    arrange(desc(estimate_pct))

  plot_4.9.2 <- create_bar_plot(
    data = barrier_results,
    x_var = estimate_pct,
    y_var = barrier_label,
    title = "Indicator 4.9.2: Barriers to Soap Access",
    subtitle = glue("Among households WITHOUT sufficient soap (n={nrow(no_soap_data)} households)\nMulti-select question - percentages may sum >100%"),
    label_position = "outside"
  )

  ggsave(here("output", "plots", "hygiene_indicator_4.9.2.png"),
         plot = plot_4.9.2, width = 10, height = 8, dpi = 300, bg = "white")

  message("  [OK] Indicator 4.9.2: Barriers to Soap Access")

  barrier_results %>%
    select(barrier_type = barrier_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 4.9.2: ", e$message)
  return(NULL)
})

# ---- Indicator 4.10: SKIP (Data Gap) ----
# Critical handwashing times knowledge not collected in survey.
# Would require question about when respondents wash hands (before eating,
# before food preparation, after defecation, etc.)

# ---- Indicator 4.11: Menstrual Material Sufficiency ----

indicator_4.11 <- tryCatch({

  menstrual_field <- "during_your_last_menstrual_period_did_you_have_enough_menstrual_materials_to_change_as_often_as_you_wanted"

  # Check if field exists and has data
  source_field <- wash_data[[menstrual_field]]
  if (is.null(source_field) || all(is.na(source_field))) {
    message("  [NO DATA] Indicator 4.11: Menstrual materials field has no data")
    return(NULL)
  }

  # Create age groups; filter to valid menstrual responses only (Yes/No)
  menstrual_data <- wash_data %>%
    filter(!!sym(menstrual_field) %in% c("Yes", "No")) %>%
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

  menstrual_design <- menstrual_data %>%
    as_survey_design(
      strata = camp_name,
      ids = pseudo_cluster,
      weights = weight,
      nest = TRUE
    )

  # Overall estimate
  overall_result <- menstrual_design %>%
    summarise(
      age_group = "Overall",
      estimate_pct = survey_mean(!!sym(menstrual_field) == "Yes", vartype = "ci", na.rm = TRUE) * 100,
      n_unweighted = unweighted(n()),
      .groups = "drop"
    ) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)

  # By age group (Tawila-wide only)
  age_results <- menstrual_design %>%
    filter(!is.na(age_group)) %>%
    group_by(age_group) %>%
    summarise(
      estimate_pct = survey_mean(!!sym(menstrual_field) == "Yes", vartype = "ci", na.rm = TRUE) * 100,
      n_unweighted = unweighted(n()),
      .groups = "drop"
    ) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)

  results_4.11 <- bind_rows(overall_result, age_results) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(age_group = factor(age_group, levels = c("Overall", "15-24", "25-34", "35-44", "45-54")))

  plot_4.11 <- ggplot(results_4.11, aes(x = estimate_pct, y = age_group)) +
    geom_col(fill = "#e36159", width = 0.6) +
    geom_errorbar(aes(xmin = ci_lower_pct, xmax = ci_upper_pct),
                  width = 0.2, linewidth = 0.5, color = "#888888") +
    geom_text(aes(label = sprintf("%d%% (n=%d)", estimate_pct, n_unweighted)),
              hjust = -0.1, size = 3.5) +
    labs(title = "Indicator 4.11: Menstrual Material Sufficiency",
         subtitle = glue("% with enough materials, by respondent age group (Tawila-wide)\nNote: respondent age used as proxy for menstruating individual"),
         x = "Percentage with Sufficient Materials",
         y = "Age Group") +
    scale_x_continuous(
      expand = expansion(mult = c(0, 0.2)),
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

  ggsave(here("output", "plots", "hygiene_indicator_4.11.png"),
         plot = plot_4.11, width = 10, height = 5, dpi = 300, bg = "white")

  message("  [OK] Indicator 4.11: Menstrual Material Sufficiency")

  results_4.11 %>%
    mutate(age_group = as.character(age_group)) %>%
    select(age_group, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 4.11: ", e$message)
  return(NULL)
})

# ---- Hygiene Excel Export ----

hygiene_sheets <- list(
  "4.1 NFI Problems" = indicator_4.1,
  "4.2 NFI Coping" = indicator_4.2,
  "4.3 Hygiene Spending" = indicator_4.3,
  "4.5 NFI Satisfaction" = indicator_4.5,
  "4.6 Handwashing Device" = indicator_4.6,
  "4.7-4.8 Water+Soap" = indicator_4.7_4.8,
  "4.9.1 Soap at Home" = indicator_4.9.1,
  "4.9.2 Soap Barriers" = indicator_4.9.2,
  "4.11 Menstrual Materials" = indicator_4.11
)

hygiene_sheets <- hygiene_sheets %>% discard(is.null)

output_file_hyg <- here("output", "wash_survey_hygiene_indicators.xlsx")
write_xlsx(hygiene_sheets, path = output_file_hyg)

message(glue("  Saved: {basename(output_file_hyg)} ({length(hygiene_sheets)} sheets)"))
message(glue("  Plots: output/plots/hygiene_indicator_*.png ({length(hygiene_sheets)} files)\n"))

# ================================================================================
# SECTION 9: SURVEY-WEIGHTED ANALYSIS - PUBLIC HEALTH INDICATOR
# ================================================================================
# Purpose: Public Health indicator (5.1) - DATA GAP (morbidity not collected)
# Output: None (skipped)
# ================================================================================

message("\n=== Processing Public Health Indicator ===\n")

# ---- Indicator 5.1: SKIP (Data Gap) ----
# WASH-related morbidity data (diarrhea, skin infections, eye infections, etc.)
# not collected in this survey. Would require question about household members
# experiencing WASH-related health issues in the past 30 days.
message("  [SKIP] Indicator 5.1: WASH-related morbidity not collected in survey\n")

# ================================================================================
# SECTION 10: SURVEY-WEIGHTED ANALYSIS - PRIORITIES INDICATORS
# ================================================================================
# Purpose: Calculate survey-weighted estimates for Priorities indicators (7.1-7.2)
# Output: Excel file with 2 indicator sheets and 2 PNG plots
# ================================================================================

message("\n=== Processing Priorities Indicators ===\n")

# ---- Indicator 7.1: Main Priority Concerns ----

indicator_7.1 <- tryCatch({

  priority_field <- "hh_h_6_1_which_of_the_following_is_your_biggest_wash_related_concern_right_now_for_your_household"

  results_7.1 <- survey_design %>%
    group_by(priority_concern = !!sym(priority_field)) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      .groups = "drop"
    ) %>%
    filter(!is.na(priority_concern)) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      concern_label = str_wrap(priority_concern, width = 45)
    ) %>%
    arrange(desc(estimate_pct))

  plot_7.1 <- ggplot(results_7.1, aes(x = estimate_pct, y = reorder(concern_label, estimate_pct))) +
    geom_col(fill = "#009999", width = 0.7) +
    geom_errorbar(aes(xmin = ci_lower_pct, xmax = ci_upper_pct),
                  width = 0.3, linewidth = 0.5, color = "#888888") +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)),
              hjust = -0.2, size = 3.5) +
    labs(title = "Indicator 7.1: Main WASH Priority Concerns",
         subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nSingle-select: biggest WASH concern for the household"),
         x = "Percentage of Households",
         y = NULL) +
    scale_x_continuous(
      expand = expansion(mult = c(0, 0.15)),
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

  ggsave(here("output", "plots", "priorities_indicator_7.1.png"),
         plot = plot_7.1, width = 10, height = 6, dpi = 300, bg = "white")

  message("  [OK] Indicator 7.1: Main Priority Concerns")

  results_7.1 %>%
    select(priority_concern = concern_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 7.1: ", e$message)
  return(NULL)
})

# ---- Indicator 7.2: Preferred Interventions ----

indicator_7.2 <- tryCatch({

  intervention_cols <- names(wash_data)[str_detect(names(wash_data), "^hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_")] %>%
    setdiff(c("hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer",
              "hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_dont_know",
              "hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_don_t_know",
              "hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_other_specify"))

  intervention_results <- map_dfr(intervention_cols, function(col) {
    survey_design %>%
      summarise(
        intervention_type = col,
        estimate_pct = survey_mean(coalesce(!!sym(col), 0) == 1, vartype = "ci") * 100,
        n_unweighted = unweighted(sum(coalesce(!!sym(col), 0) == 1))
      ) %>%
      rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp)
  }) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    mutate(
      intervention_label = str_remove(intervention_type, "hh_h_6_2_if_your_household_were_to_receive_support_to_address_your_concerns_what_would_you_prefer_") %>%
        str_replace_all("_", " ") %>%
        str_to_sentence() %>%
        str_wrap(width = 50)
    ) %>%
    arrange(desc(estimate_pct))

  plot_7.2 <- ggplot(intervention_results, aes(x = estimate_pct, y = reorder(intervention_label, estimate_pct))) +
    geom_col(fill = "#009999", width = 0.7) +
    geom_errorbar(aes(xmin = ci_lower_pct, xmax = ci_upper_pct),
                  width = 0.3, linewidth = 0.5, color = "#888888") +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)),
              hjust = -0.2, size = 3.5) +
    labs(title = "Indicator 7.2: Preferred WASH Interventions",
         subtitle = glue("Overall Tawila-wide estimate (n={nrow(wash_data)} households)\nMulti-select question - percentages may sum >100%"),
         x = "Percentage of Households",
         y = NULL) +
    scale_x_continuous(
      expand = expansion(mult = c(0, 0.15)),
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

  ggsave(here("output", "plots", "priorities_indicator_7.2.png"),
         plot = plot_7.2, width = 10, height = 10, dpi = 300, bg = "white")

  message("  [OK] Indicator 7.2: Preferred Interventions")

  intervention_results %>%
    select(intervention_type = intervention_label, estimate_pct, ci_lower_pct, ci_upper_pct, n_unweighted)

}, error = function(e) {
  message("  [ERROR] Indicator 7.2: ", e$message)
  return(NULL)
})

# ---- Priorities Excel Export ----

priorities_sheets <- list(
  "7.1 Priority Concerns" = indicator_7.1,
  "7.2 Preferred Interventions" = indicator_7.2
)

priorities_sheets <- priorities_sheets %>% discard(is.null)

output_file_pri <- here("output", "wash_survey_priorities_indicators.xlsx")
write_xlsx(priorities_sheets, path = output_file_pri)

message(glue("  Saved: {basename(output_file_pri)} ({length(priorities_sheets)} sheets)"))
message(glue("  Plots: output/plots/priorities_indicator_*.png ({length(priorities_sheets)} files)\n"))

# ================================================================================
# SECTION 11: SURVEY-WEIGHTED ANALYSIS - DISAGGREGATION INDICATORS
# ================================================================================
# Purpose: Calculate survey-weighted estimates for Table 1 disaggregation indicators
# Output: Excel file with 9 indicator sheets and 10 PNG plots
# ================================================================================

message("\n=== Processing Table 1: Disaggregation Indicators ===\n")

# ---- Data Cleaning: Handle Outliers in Elderly Count Fields ----

wash_data <- wash_data %>%
  mutate(
    no_of_men_60_in_hh = if_else(
      as.numeric(no_of_men_60_in_hh) > 4,
      NA_character_,
      no_of_men_60_in_hh
    ),
    no_of_women_60_in_hh = if_else(
      as.numeric(no_of_women_60_in_hh) > 4,
      NA_character_,
      no_of_women_60_in_hh
    )
  )

# ---- Derive Binary Indicators ----

wash_data <- wash_data %>%
  mutate(
    # Indicator 4: Recent arrivals
    recent_arrival_bin = if_else(
      did_people_arrive_two_weeks_ago_into_tawila == "Yes", 1, 0
    ),
    
    # Indicator 5: Children under 5
    children_under5_bin = if_else(
      do_you_have_members_less_than_5_years_old == "Yes", 1, 0
    ),
    
    # Indicator 6: Elderly 60+ (any men OR women)
    elderly_60plus_bin = if_else(
      (as.numeric(no_of_men_60_in_hh) > 0) | (as.numeric(no_of_women_60_in_hh) > 0),
      1, 0, missing = 0
    ),
    
    # Indicator 7: Disabled members
    disabled_members_bin = if_else(
      as.numeric(no_of_people_with_disabilities_in_hh_optional) > 0, 1, 0, missing = 0
    ),
    
    # Indicator 8: PLW
    plw_bin = if_else(
      do_you_have_members_with_pregnant_or_lactating_women == "Yes", 1, 0
    ),
    
    # Indicator 9: Malnutrition treatment
    malnutrition_treatment_bin = if_else(
      do_you_have_members_with_child_that_is_currently_receiving_malnutrition_treatment == "Yes", 1, 0
    )
  )

# ---- Recreate Survey Design with Updated Data ----

survey_design <- wash_data %>%
  as_survey_design(
    strata = camp_name,
    ids = pseudo_cluster,
    weights = weight,
    nest = TRUE
  )

# ---- Indicator 1: Camp Distribution ----

indicator_1 <- tryCatch({
  results_1 <- survey_design %>%
    group_by(camp_name) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      n_effective = n(),
      .groups = "drop"
    ) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round)) %>%
    arrange(desc(n_unweighted))
  
  if (abs(sum(results_1$estimate_pct) - 100) > 5) {
    warning("Indicator 1: Categories sum to ", round(sum(results_1$estimate_pct), 1), "%, expected ~100%")
  }
  
  # Custom plot without error bars (descriptive statistic, not population estimate)
  plot_1 <- ggplot(results_1, aes(x = estimate_pct, y = reorder(camp_name, estimate_pct))) +
    geom_col(fill = "#009999", width = 0.7) +
    geom_text(aes(label = sprintf("%d%%", estimate_pct)), hjust = -0.2, size = 3.5) +
    labs(
      title = "Indicator 1: Camp Distribution",
      subtitle = glue("n = {sum(results_1$n_unweighted)} households"),
      x = "Percentage of Households",
      y = NULL
    ) +
    scale_x_continuous(
      expand = expansion(mult = c(0, 0.15)),
      limits = c(0, NA),
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
  
  ggsave(here("output", "plots", "disaggregation_indicator_1.png"),
         plot = plot_1, width = 8, height = 4, dpi = 300, bg = "white")
  
  message("  [OK] Indicator 1: Camp Distribution")
  results_1
}, error = function(e) {
  message("  [ERROR] Indicator 1: ", e$message)
  return(NULL)
})

# ---- Indicator 2: Respondent Gender ----

indicator_2 <- tryCatch({
  results_2 <- survey_design %>%
    group_by(gender = gender_of_the_househld) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      n_effective = n(),
      .groups = "drop"
    ) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))
  
  # Filter to Female only for plot
  plot_data <- results_2 %>% filter(gender == "Female")
  
  plot_2 <- create_bar_plot(
    data = plot_data,
    x_var = estimate_pct,
    y_var = gender,
    title = "Indicator 2: Gender of Survey Respondent",
    subtitle = glue("Female respondents: n = {plot_data$n_unweighted}; Effective n = {round(plot_data$n_effective)}"),
    fill_color = "#009999",
    x_limits = c(0, 100),
    label_position = "outside"
  )
  
  ggsave(here("output", "plots", "disaggregation_indicator_2.png"),
         plot = plot_2, width = 8, height = 3, dpi = 300, bg = "white")
  
  message("  [OK] Indicator 2: Respondent Gender")
  results_2
}, error = function(e) {
  message("  [ERROR] Indicator 2: ", e$message)
  return(NULL)
})

# ---- Indicator 3a: Household Head Age Distribution ----

indicator_3a <- tryCatch({
  age_stats <- survey_design %>%
    summarise(
      mean_age = survey_mean(as.numeric(age_of_hh_respondent), vartype = "ci", na.rm = TRUE),
      median_age = survey_median(as.numeric(age_of_hh_respondent), na.rm = TRUE),
      n_unweighted = unweighted(sum(!is.na(age_of_hh_respondent))),
      n_effective = n()
    )
  
  plot_3a <- ggplot(wash_data %>% filter(!is.na(age_of_hh_respondent)),
                    aes(x = as.numeric(age_of_hh_respondent))) +
    geom_histogram(binwidth = 5, boundary = 15, fill = "#009999", color = "white") +
    geom_vline(xintercept = age_stats$median_age, linetype = "dashed",
               color = "#e36159", linewidth = 0.8) +
    labs(
      title = "Indicator 3a: Age Distribution of Household Heads",
      subtitle = glue("Mean: {round(age_stats$mean_age)} years (95% CI: {round(age_stats$mean_age_low)}-{round(age_stats$mean_age_upp)}); Median: {round(age_stats$median_age)} years"),
      x = "Age (years)",
      y = "Number of Households"
    ) +
    scale_x_continuous(breaks = seq(15, 90, 5), limits = c(15, 90)) +
    theme_minimal(base_size = 12) +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      plot.subtitle = element_text(color = "grey40", size = 11),
      panel.grid.minor = element_blank()
    )
  
  ggsave(here("output", "plots", "disaggregation_indicator_3a.png"),
         plot = plot_3a, width = 10, height = 6, dpi = 300, bg = "white")
  
  message("  [OK] Indicator 3a: HoH Age Distribution")
  
  age_stats %>%
    mutate(across(c(mean_age, mean_age_low, mean_age_upp, median_age), round)) %>%
    rename(
      mean_age_ci_lower = mean_age_low,
      mean_age_ci_upper = mean_age_upp
    )
}, error = function(e) {
  message("  [ERROR] Indicator 3a: ", e$message)
  return(NULL)
})

# ---- Indicator 3b: Household Head Gender ----

indicator_3b <- tryCatch({
  results_3b <- survey_design %>%
    group_by(gender = gender_of_the_househld) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      n_effective = n(),
      .groups = "drop"
    ) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))
  
  # Filter to Female only for plot
  plot_data <- results_3b %>% filter(gender == "Female")
  
  plot_3b <- create_bar_plot(
    data = plot_data,
    x_var = estimate_pct,
    y_var = gender,
    title = "Indicator 3b: Gender of Household Head",
    subtitle = glue("Female HoH: n = {plot_data$n_unweighted}; Effective n = {round(plot_data$n_effective)}"),
    fill_color = "#009999",
    x_limits = c(0, 100),
    label_position = "outside"
  )
  
  ggsave(here("output", "plots", "disaggregation_indicator_3b.png"),
         plot = plot_3b, width = 8, height = 3, dpi = 300, bg = "white")
  
  message("  [OK] Indicator 3b: HoH Gender")
  results_3b
}, error = function(e) {
  message("  [ERROR] Indicator 3b: ", e$message)
  return(NULL)
})

# ---- Indicator 4: Recent Arrivals ----

indicator_4 <- tryCatch({
  results_4 <- survey_design %>%
    group_by(category = if_else(recent_arrival_bin == 1, "Yes", "No")) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      n_effective = n(),
      .groups = "drop"
    ) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))
  
  # Filter to Yes only for plot
  plot_data <- results_4 %>% filter(category == "Yes")
  
  plot_4 <- create_bar_plot(
    data = plot_data,
    x_var = estimate_pct,
    y_var = category,
    title = "Indicator 4: Recent Arrivals (Within 2 Weeks)",
    subtitle = glue("Yes: n = {plot_data$n_unweighted}; Effective n = {round(plot_data$n_effective)}"),
    fill_color = "#009999",
    x_limits = c(0, 100),
    label_position = "outside"
  )
  
  ggsave(here("output", "plots", "disaggregation_indicator_4.png"),
         plot = plot_4, width = 8, height = 3, dpi = 300, bg = "white")
  
  message("  [OK] Indicator 4: Recent Arrivals")
  results_4
}, error = function(e) {
  message("  [ERROR] Indicator 4: ", e$message)
  return(NULL)
})

# ---- Indicator 5: Households with Children Under 5 ----

indicator_5 <- tryCatch({
  results_5 <- survey_design %>%
    group_by(category = if_else(children_under5_bin == 1, "Yes", "No")) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      n_effective = n(),
      .groups = "drop"
    ) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))
  
  # Filter to Yes only for plot
  plot_data <- results_5 %>% filter(category == "Yes")
  
  plot_5 <- create_bar_plot(
    data = plot_data,
    x_var = estimate_pct,
    y_var = category,
    title = "Indicator 5: Households with Children Under 5",
    subtitle = glue("Yes: n = {plot_data$n_unweighted}; Effective n = {round(plot_data$n_effective)}"),
    fill_color = "#009999",
    x_limits = c(0, 100),
    label_position = "outside"
  )
  
  ggsave(here("output", "plots", "disaggregation_indicator_5.png"),
         plot = plot_5, width = 8, height = 3, dpi = 300, bg = "white")
  
  message("  [OK] Indicator 5: Children Under 5")
  results_5
}, error = function(e) {
  message("  [ERROR] Indicator 5: ", e$message)
  return(NULL)
})

# ---- Indicator 6: Households with Elderly (60+) ----

indicator_6 <- tryCatch({
  results_6 <- survey_design %>%
    group_by(category = if_else(elderly_60plus_bin == 1, "Yes", "No")) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      n_effective = n(),
      .groups = "drop"
    ) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))
  
  # Filter to Yes only for plot
  plot_data <- results_6 %>% filter(category == "Yes")
  
  plot_6 <- create_bar_plot(
    data = plot_data,
    x_var = estimate_pct,
    y_var = category,
    title = "Indicator 6: Households with Elderly Members (60+)",
    subtitle = glue("Yes: n = {plot_data$n_unweighted}; Effective n = {round(plot_data$n_effective)}"),
    fill_color = "#009999",
    x_limits = c(0, 100),
    label_position = "outside"
  )
  
  ggsave(here("output", "plots", "disaggregation_indicator_6.png"),
         plot = plot_6, width = 8, height = 3, dpi = 300, bg = "white")
  
  message("  [OK] Indicator 6: Elderly 60+")
  results_6
}, error = function(e) {
  message("  [ERROR] Indicator 6: ", e$message)
  return(NULL)
})

# ---- Indicator 7: Households with Disabled Members ----

indicator_7 <- tryCatch({
  results_7 <- survey_design %>%
    group_by(category = if_else(disabled_members_bin == 1, "Yes", "No")) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      n_effective = n(),
      .groups = "drop"
    ) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))
  
  # Filter to Yes only for plot
  plot_data <- results_7 %>% filter(category == "Yes")
  
  plot_7 <- create_bar_plot(
    data = plot_data,
    x_var = estimate_pct,
    y_var = category,
    title = "Indicator 7: Households with Disabled Members",
    subtitle = glue("Yes: n = {plot_data$n_unweighted}; Effective n = {round(plot_data$n_effective)}"),
    fill_color = "#009999",
    x_limits = c(0, 100),
    label_position = "outside"
  )
  
  ggsave(here("output", "plots", "disaggregation_indicator_7.png"),
         plot = plot_7, width = 8, height = 3, dpi = 300, bg = "white")
  
  message("  [OK] Indicator 7: Disabled Members")
  results_7
}, error = function(e) {
  message("  [ERROR] Indicator 7: ", e$message)
  return(NULL)
})

# ---- Indicator 8: Households with Pregnant/Lactating Women ----

indicator_8 <- tryCatch({
  results_8 <- survey_design %>%
    group_by(category = if_else(plw_bin == 1, "Yes", "No")) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      n_effective = n(),
      .groups = "drop"
    ) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))
  
  # Filter to Yes only for plot
  plot_data <- results_8 %>% filter(category == "Yes")
  
  plot_8 <- create_bar_plot(
    data = plot_data,
    x_var = estimate_pct,
    y_var = category,
    title = "Indicator 8: Households with Pregnant/Lactating Women",
    subtitle = glue("Yes: n = {plot_data$n_unweighted}; Effective n = {round(plot_data$n_effective)}"),
    fill_color = "#009999",
    x_limits = c(0, 100),
    label_position = "outside"
  )
  
  ggsave(here("output", "plots", "disaggregation_indicator_8.png"),
         plot = plot_8, width = 8, height = 3, dpi = 300, bg = "white")
  
  message("  [OK] Indicator 8: PLW")
  results_8
}, error = function(e) {
  message("  [ERROR] Indicator 8: ", e$message)
  return(NULL)
})

# ---- Indicator 9: Households with Children Receiving Malnutrition Treatment ----

indicator_9 <- tryCatch({
  results_9 <- survey_design %>%
    group_by(category = if_else(malnutrition_treatment_bin == 1, "Yes", "No")) %>%
    summarise(
      estimate_pct = survey_mean(vartype = "ci") * 100,
      n_unweighted = unweighted(n()),
      n_effective = n(),
      .groups = "drop"
    ) %>%
    rename(ci_lower_pct = estimate_pct_low, ci_upper_pct = estimate_pct_upp) %>%
    mutate(across(c(estimate_pct, ci_lower_pct, ci_upper_pct), round))
  
  # Filter to Yes only for plot
  plot_data <- results_9 %>% filter(category == "Yes")
  
  plot_9 <- create_bar_plot(
    data = plot_data,
    x_var = estimate_pct,
    y_var = category,
    title = "Indicator 9: Households with Children Receiving Malnutrition Treatment",
    subtitle = glue("Yes: n = {plot_data$n_unweighted}; Effective n = {round(plot_data$n_effective)}"),
    fill_color = "#009999",
    x_limits = c(0, 100),
    label_position = "outside"
  )
  
  ggsave(here("output", "plots", "disaggregation_indicator_9.png"),
         plot = plot_9, width = 8, height = 3, dpi = 300, bg = "white")
  
  message("  [OK] Indicator 9: Malnutrition Treatment")
  results_9
}, error = function(e) {
  message("  [ERROR] Indicator 9: ", e$message)
  return(NULL)
})

# ---- Export Disaggregation Indicators to Excel ----

message("\n=== Exporting disaggregation indicators to Excel ===")

disaggregation_sheets <- list(
  "1 Camp Distribution" = indicator_1,
  "2 Respondent Gender" = indicator_2,
  "3a HoH Age Stats" = indicator_3a,
  "3b HoH Gender" = indicator_3b,
  "4 Recent Arrivals" = indicator_4,
  "5 Children Under 5" = indicator_5,
  "6 Elderly 60+" = indicator_6,
  "7 Disabled Members" = indicator_7,
  "8 PLW" = indicator_8,
  "9 Malnutrition" = indicator_9
)

disaggregation_sheets <- disaggregation_sheets %>% discard(is.null)

disagg_output_file <- here("output", "wash_survey_disaggregation_indicators.xlsx")
write_xlsx(disaggregation_sheets, path = disagg_output_file)

message(glue("  Saved: {basename(disagg_output_file)} ({length(disaggregation_sheets)} sheets)"))
message(glue("  Plots: output/plots/disaggregation_indicator_*.png (10 files)\n"))

# ================================================================================
# SECTION 12: FINAL OUTPUT & SUMMARY
# ================================================================================
# Purpose: Save final household and container datasets, display summary statistics
# Output: wash_survey_hh_level.xlsx/rds and wash_survey_container_level.xlsx
# ================================================================================

# Create output directory and save final datasets
output_dir <- here("output")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# Save household-level dataset in Excel and RDS formats
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
