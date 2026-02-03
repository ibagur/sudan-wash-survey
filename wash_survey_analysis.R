# Kobo Data Retrieval and Transformation
# Purpose: Download WASH survey data from KoboToolbox and prepare for analysis
# Date: 2026-02-03
#
# Implementation Notes:
# - Sheet name is "choices" (not "KoboFormChoices")
# - 4 list columns remain after expansion: attachments, geolocation, tags, notes
#   These are Kobo system metadata, not WASH survey questions
# - Excel warnings about unrecognized data types are expected for these columns
# - Verification (2026-02-03): 263 submissions → 627 rows after expansion, 117 columns

# Load required libraries -----
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

# Load Kobo configuration
config <- read_yaml(kobo_config_path)

# Validate configuration
required_fields <- c("user", "password", "asset_id", "url")
missing <- setdiff(required_fields, names(config$kobo))
if (length(missing) > 0) {
  stop(glue("Missing required config fields: {paste(missing, collapse = ', ')}"))
}

# Download Kobo data -----
endpoint <- glue("https://{config$kobo$url}/api/v2/assets/{config$kobo$asset_id}/data.json")

response <- GET(
  endpoint,
  authenticate(config$kobo$user, config$kobo$password, type = "basic"),
  timeout(120)
)

stop_for_status(response, task = glue("download data from KoboToolbox (asset: {config$kobo$asset_id})"))

# Parse JSON response -----
json_text <- content(response, as = "text", encoding = "UTF-8")
parsed <- fromJSON(json_text, flatten = TRUE, simplifyDataFrame = TRUE)

if (!("results" %in% names(parsed))) {
  stop("API response missing 'results' field")
}

wash_data <- as_tibble(parsed$results)

if (nrow(wash_data) == 0) {
  stop("No data returned from API")
}

message(glue("Downloaded {nrow(wash_data)} submissions from KoboToolbox"))

# Expand repeat groups -----
list_cols <- wash_data %>%
  select(where(is.list)) %>%
  names()

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
simple_names <- str_extract(names(wash_data), "[^/]+$")
clean_names <- make_clean_names(simple_names)
clean_names <- make.unique(clean_names, sep = "_")
names(wash_data) <- clean_names

# Load value mapping (English labels only) -----
if (!file.exists(mapping_file_path)) {
  stop(glue("Mapping file not found: {mapping_file_path}"))
}

mapping_df <- read_excel(mapping_file_path, sheet = "choices")

if (!("name" %in% names(mapping_df)) || !("label::English (en)" %in% names(mapping_df))) {
  stop("Mapping file missing required columns: 'name' or 'label::English (en)'")
}

mapping <- setNames(
  mapping_df[["label::English (en)"]],
  mapping_df[["name"]]
)

# Apply value mapping to character columns
wash_data <- wash_data %>%
  mutate(across(where(is.character), ~ {
    mapped <- mapping[.x]
    coalesce(mapped, .x)
  }))

# Clean string values (remove control characters, truncate long strings)
wash_data <- wash_data %>%
  mutate(across(where(is.character), ~ {
    cleaned <- str_replace_all(.x, "[\\x00-\\x1f]", "")
    str_trunc(cleaned, width = 32000, ellipsis = "...")
  }))

# Save cleaned data -----
output_dir <- here("output")
if (!dir.exists(output_dir)) {
  dir.create(output_dir, recursive = TRUE)
}

output_rds_path <- here("output", "wash_survey_raw.rds")
output_xlsx_path <- here("output", "wash_survey_raw.xlsx")

saveRDS(wash_data, output_rds_path)
write_xlsx(wash_data, output_xlsx_path)

message(glue("Cleaned data saved to RDS: {output_rds_path}"))
message(glue("Cleaned data saved to Excel: {output_xlsx_path}"))
message(glue("Final dataset: {nrow(wash_data)} rows x {ncol(wash_data)} columns"))
