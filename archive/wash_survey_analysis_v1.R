# Kobo Data Retrieval and Transformation
# Purpose: Download WASH survey data from KoboToolbox with proper multiple_select handling
# Date: 2026-02-05
#
# Outputs:
# 1. Container-level dataset (882 rows) - One row per water container
# 2. Household-level dataset (371 rows) - One row per household with aggregations
#
# Both datasets include:
# - English column labels (not XML codes)
# - Multiple_select summary columns (space-separated English labels)
# - Boolean indicator columns (0/1) for each multiple_select choice
#
# Approach: Use /data.json endpoint for repeat groups, process multiple_select inline

library(tidyverse)
library(httr)
library(jsonlite)
library(yaml)
library(here)
library(readxl)
library(writexl)
library(glue)
library(janitor)

# Configuration -----
kobo_config_path <- here("config.yaml")
mapping_file_path <- here("data", "Kobo version_02-Feb-2026.xlsx")

config <- read_yaml(kobo_config_path)

# Download data from /data.json endpoint (needed for repeat groups) -----
endpoint <- glue("https://{config$kobo$url}/api/v2/assets/{config$kobo$asset_id}/data.json")

response <- GET(
  endpoint,
  authenticate(config$kobo$user, config$kobo$password, type = "basic"),
  timeout(120)
)

stop_for_status(response, task = "download data from KoboToolbox")

json_text <- content(response, as = "text", encoding = "UTF-8")
parsed <- fromJSON(json_text, flatten = TRUE, simplifyDataFrame = TRUE)

wash_data <- as_tibble(parsed$results)
message(glue("Downloaded {nrow(wash_data)} submissions"))

# Store pre-expansion data for household-level
wash_data_hh_pre <- wash_data

# Expand repeat groups -----
list_cols <- wash_data %>% select(where(is.list)) %>% names()

if (length(list_cols) > 0) {
  wash_data <- reduce(list_cols, function(data, col) {
    has_nested_lists <- data[[col]] %>%
      map_lgl(~ is.list(.x) && length(.x) > 0) %>%
      any()

    if (has_nested_lists) {
      data %>%
        unnest_longer(all_of(col), keep_empty = TRUE) %>%
        unnest_wider(all_of(col), names_sep = "_")
    } else {
      data
    }
  }, .init = wash_data)
}

# Clean column names -----
leaf_names <- str_extract(names(wash_data), "[^/]+$")
clean_names <- make_clean_names(leaf_names)
clean_names <- make.unique(clean_names, sep = "_")
names(wash_data) <- clean_names

# Create registry for later reference
kobo_leaf_registry <- setNames(leaf_names, clean_names)

# Load survey definitions -----
survey_def <- read_excel(mapping_file_path, sheet = "survey")
choices_def <- read_excel(mapping_file_path, sheet = "choices")

# Identify select_multiple questions -----
multiselect_qs <- survey_def %>%
  filter(str_detect(type, "^select_multiple")) %>%
  select(name, type) %>%
  mutate(
    list_name = str_extract(type, "(?<=select_multiple )\\w+"),
    clean_name = map_chr(name, ~ {
      matches <- clean_names[kobo_leaf_registry == .x]
      if (length(matches) > 0) matches[1] else NA_character_
    })
  ) %>%
  filter(!is.na(clean_name), clean_name %in% names(wash_data))

message(glue("Found {nrow(multiselect_qs)} select_multiple questions to process"))

# Process each select_multiple question inline -----
# For each question, create boolean columns for each choice

for (i in seq_len(nrow(multiselect_qs))) {
  col_name <- multiselect_qs$clean_name[i]
  list_name <- multiselect_qs$list_name[i]

  # Get choices for this list
  choices <- choices_def %>%
    filter(list_name == !!list_name) %>%
    select(xml_code = name, english_label = `label::English (en)`)

  if (nrow(choices) == 0) {
    warning(glue("No choices found for {list_name}"))
    next
  }

  # Convert summary column: XML codes → English labels
  wash_data <- wash_data %>%
    mutate(
      "{col_name}" := map_chr(.data[[col_name]], function(val) {
        if (is.na(val) || val == "") return(NA_character_)

        # Split space-separated codes
        codes <- str_trim(str_split(val, " ")[[1]])
        codes <- codes[codes != ""]

        # Map to English
        labels <- choices$english_label[match(codes, choices$xml_code)]
        labels <- na.omit(labels)

        if (length(labels) == 0) return(NA_character_)
        paste(labels, collapse = " ")
      })
    )

  # Create boolean columns
  for (j in seq_len(nrow(choices))) {
    bool_col_name <- paste0(col_name, "_", make_clean_names(choices$english_label[j]))
    choice_label <- choices$english_label[j]

    wash_data[[bool_col_name]] <- as.integer(
      !is.na(wash_data[[col_name]]) &
        str_detect(wash_data[[col_name]], fixed(choice_label))
    )
  }

  message(glue("Processed {col_name}: {nrow(choices)} boolean columns created"))
}

message(glue("Container-level: {nrow(wash_data)} rows x {ncol(wash_data)} columns"))

# Create household-level aggregations -----
wash_data_hh <- wash_data %>%
  group_by(id) %>%
  mutate(
    num_containers_reported = n(),
    total_containers_owned = sum(as.numeric(number_of_containers), na.rm = TRUE),
    total_volume_liters = sum(as.numeric(volume_liters) * as.numeric(number_of_containers), na.rm = TRUE),
    container_types_present = paste(unique(na.omit(container_type)), collapse = "; ")
  ) %>%
  slice(1) %>%
  ungroup()

# Apply value mapping for all other columns -----
mapping <- setNames(
  choices_def[["label::English (en)"]],
  choices_def[["name"]]
)

wash_data <- wash_data %>%
  mutate(across(where(is.character), ~ coalesce(mapping[.x], .x)))

wash_data_hh <- wash_data_hh %>%
  mutate(across(where(is.character), ~ coalesce(mapping[.x], .x)))

# Clean string values -----
wash_data <- wash_data %>%
  mutate(across(where(is.character), ~ {
    cleaned <- str_replace_all(.x, "[\\x00-\\x1f]", "")
    str_trunc(cleaned, width = 32000, ellipsis = "...")
  }))

wash_data_hh <- wash_data_hh %>%
  mutate(across(where(is.character), ~ {
    cleaned <- str_replace_all(.x, "[\\x00-\\x1f]", "")
    str_trunc(cleaned, width = 32000, ellipsis = "...")
  }))

# Rename and reorder columns -----
survey_named <- survey_def %>%
  mutate(row_pos = row_number()) %>%
  filter(!is.na(name), nchar(name) > 0)

question_labels <- setNames(survey_named[["label::English (en)"]], survey_named$name)
question_positions <- setNames(survey_named$row_pos, survey_named$name)

computed_cols <- c("num_containers_reported", "total_containers_owned",
                   "total_volume_liters", "container_types_present")

# Function to reorder and relabel
reorder_columns <- function(df) {
  current_cols <- names(df)

  # Separate boolean columns (contain underscore pattern from select_multiple)
  boolean_pattern <- paste0("^(", paste(multiselect_qs$clean_name, collapse = "|"), ")_")
  boolean_cols <- current_cols[str_detect(current_cols, boolean_pattern)]
  base_cols <- setdiff(current_cols, boolean_cols)

  # Get positions for base columns
  leaf <- kobo_leaf_registry[base_cols]
  new_labels <- coalesce(question_labels[leaf], base_cols)

  positions <- ifelse(
    !is.na(question_positions[leaf]),
    as.numeric(question_positions[leaf]),
    ifelse(base_cols %in% computed_cols, 9999.0, 0.0)
  )

  # Boolean columns inherit parent position with small offset
  bool_positions <- map_dbl(boolean_cols, function(col) {
    parent <- str_extract(col, "^[^_]+(_[0-9]+)?")
    parent_idx <- which(base_cols == parent)
    if (length(parent_idx) > 0) {
      positions[parent_idx] + 0.001
    } else {
      9999.0
    }
  })

  # Combine and sort
  all_cols <- c(base_cols, boolean_cols)
  all_positions <- c(positions, bool_positions)
  all_labels <- c(new_labels, boolean_cols)

  ord <- order(all_positions)
  df <- df[, all_cols[ord]]

  # Clean names
  final_names <- make_clean_names(all_labels[ord])
  final_names <- make.unique(final_names, sep = "_")
  names(df) <- final_names

  df
}

wash_data <- reorder_columns(wash_data)
wash_data_hh <- reorder_columns(wash_data_hh)

# Save outputs -----
output_dir <- here("output")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

write_xlsx(wash_data, here("output", "wash_survey_container_level.xlsx"))
saveRDS(wash_data, here("output", "wash_survey_container_level.rds"))

write_xlsx(wash_data_hh, here("output", "wash_survey_hh_level.xlsx"))
saveRDS(wash_data_hh, here("output", "wash_survey_hh_level.rds"))

message(glue("
Container-level: {nrow(wash_data)} rows x {ncol(wash_data)} columns
Household-level: {nrow(wash_data_hh)} rows x {ncol(wash_data_hh)} columns
Outputs saved to: {output_dir}
"))
