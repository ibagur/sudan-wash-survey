# Generate Integrated Dashboard
# Purpose: Combine NWC water disruption data with Kobo 5W activity data in unified dashboard
# Date: 2026-01-29

# Load required libraries -----
library(tidyverse)  # Data manipulation and visualization
library(readxl)     # Excel file reading
library(writexl)    # Excel file writing
library(janitor)    # clean_names() utility
library(here)       # Reproducible file paths
library(glue)       # String interpolation
library(httr)       # HTTP requests for API calls
library(jsonlite)   # JSON parsing
library(yaml)       # YAML config file parsing
library(sf)         # Spatial data handling
library(leaflet)    # Interactive web maps
library(htmltools)  # HTML generation for map styling
library(scales)     # Number formatting
library(rmarkdown)  # R Markdown rendering
library(reactable)  # Interactive tables


# Configuration -----

# Constants
hh <- 3  # Household size multiplier

# File paths
nwc_data_path <- here("data", "nwc_parish_raw_20260127.xlsx")
admin_lookup_path <- here("data", "jam_admgz_sdc_20251106.xlsx")
gis_data_path <- here("gis", "202_admn_20251106.zip")
kobo_config_path <- here("config.yaml")

# Kobo cutoff date (YYYYMMDD format)
cutoff_date <- "20251201"

# Color scheme
col_bubble <- "#28A1d2"
col_border <- "#2490BD"

message("Starting integrated dashboard generation")

# Helper Functions -----

# Standardize parish names for matching
standardize_parish <- function(name) {
  str_trim(name) %>%
    # Convert "Saint" to "St. " (e.g., "Saint Mary" → "St. Mary")
    str_replace_all("^Saint\\s+", "St. ") %>%
    # Convert "ST." to "St. " (e.g., "ST.ELIZABETH" → "St. ELIZABETH")
    str_replace_all("^ST\\.", "St. ") %>%
    # Ensure space after "St." (e.g., "St.Mary" → "St. Mary")
    str_replace_all("^St\\.(?! )", "St. ") %>%
    # Apply title case
    str_to_title()
}


# NWC Data Pipeline -----

# Read raw NWC parish data
nwc_raw <- read_excel(nwc_data_path)
adm1_lookup <- read_excel(admin_lookup_path, sheet = "ADM1")

message(glue("Loaded NWC data: {nrow(nwc_raw)} parishes"))

# Transform NWC data
nwc_transformed <- nwc_raw %>%
  clean_names() %>%
  # Adjust St. Catherine by subtracting Portmore customers
  mutate(
    portmore_total = total_customers[parish == "Portmore"],
    total_customers = if_else(
      parish == "St. Catherine (incl. Portmore)",
      total_customers - portmore_total,
      total_customers
    ),
    parish = if_else(
      parish == "St. Catherine (incl. Portmore)",
      "St. Catherine",
      parish
    )
  ) %>%
  select(-portmore_total) %>%
  # Filter out rows with zero percentage affected
  filter(percentage_affected != 0) %>%
  # Recalculate percentage_affected
  mutate(
    percentage_affected = number_of_affected_customers / total_customers
  ) %>%
  # Create individual-level estimates
  mutate(
    total_ind = total_customers * hh,
    affected_ind = number_of_affected_customers * hh
  ) %>%
  # Prepare parish names for matching with admin lookup
  mutate(
    parish_for_match = str_replace_all(parish, "^St\\.", "Saint")
  ) %>%
  # Join with administrative codes
  left_join(
    adm1_lookup %>%
      select(ADM1_EN, ADM1_PCODE) %>%
      rename(parish_for_match = ADM1_EN),
    by = "parish_for_match"
  ) %>%
  rename(adm1_pcode = ADM1_PCODE) %>%
  select(-parish_for_match) %>%
  # Add standardized parish names
  mutate(parish_std = standardize_parish(parish))

message(glue("NWC data transformed: {nrow(nwc_transformed)} parishes"))


# Kobo 5W Data Pipeline -----

# Load Kobo configuration
config <- read_yaml(kobo_config_path)

# Validate configuration
required_fields <- c("user", "password", "asset_id", "url", "mapping_file")
missing <- setdiff(required_fields, names(config$kobo))
if (length(missing) > 0) {
  stop(glue("Missing required config fields: {paste(missing, collapse = ', ')}"))
}

# Download Kobo data
endpoint <- glue("https://{config$kobo$url}/api/v2/assets/{config$kobo$asset_id}/data.json")

response <- GET(
  endpoint,
  authenticate(config$kobo$user, config$kobo$password, type = "basic"),
  timeout(120)
)

stop_for_status(response, task = glue("download data from KoboToolbox (asset: {config$kobo$asset_id})"))

# Parse JSON response
json_text <- content(response, as = "text", encoding = "UTF-8")
parsed <- fromJSON(json_text, flatten = TRUE, simplifyDataFrame = TRUE)

if (!("results" %in% names(parsed))) {
  stop("API response missing 'results' field")
}

kobo_5w_data <- as_tibble(parsed$results)

if (nrow(kobo_5w_data) == 0) {
  stop("No data returned from API")
}

message(glue("Downloaded {nrow(kobo_5w_data)} submissions from KoboToolbox"))

# Expand repeat groups
list_cols <- kobo_5w_data %>%
  select(where(is.list)) %>%
  names()

if (length(list_cols) > 0) {
  kobo_5w_data <- reduce(list_cols, function(data, col) {
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
  }, .init = kobo_5w_data)
}

# Apply cutoff date filter
if (!is.null(cutoff_date)) {
  if (!("_submission_time" %in% names(kobo_5w_data))) {
    warning("No _submission_time column found - skipping cutoff filter")
  } else {
    cutoff <- as.Date(cutoff_date, format = "%Y%m%d")

    kobo_5w_data <- kobo_5w_data %>%
      mutate(submission_date = as.Date(.data$`_submission_time`)) %>%
      filter(submission_date >= cutoff) %>%
      select(-submission_date)
  }
}

# Clean column names
simple_names <- str_extract(names(kobo_5w_data), "[^/]+$")
clean_names <- make_clean_names(simple_names)
clean_names <- make.unique(clean_names, sep = "_")
names(kobo_5w_data) <- clean_names

# Load and apply value mapping
mapping_path <- here(config$kobo$mapping_file)

if (!file.exists(mapping_path)) {
  stop(glue("Mapping file not found: {mapping_path}"))
}

mapping_df <- read_excel(mapping_path, sheet = "KoboFormChoices")

if (!("name" %in% names(mapping_df) || !"label::English (en)" %in% names(mapping_df))) {
  stop("Mapping file missing required columns: 'name' or 'label::English (en)'")
}

mapping <- setNames(
  mapping_df[["label::English (en)"]],
  mapping_df[["name"]]
)

# Apply mapping to character columns
kobo_5w_data <- kobo_5w_data %>%
  mutate(across(where(is.character), ~ {
    mapped <- mapping[.x]
    coalesce(mapped, .x)
  }))

# Clean string values
kobo_5w_data <- kobo_5w_data %>%
  mutate(across(where(is.character), ~ {
    cleaned <- str_replace_all(.x, "[\\x00-\\x1f]", "")
    str_trunc(cleaned, width = 32000, ellipsis = "...")
  }))

# Standardize column names and order
reference_columns <- c(
  "LeadOrganization_type", "LeadOrganization_name", "LeadOrganization_name_2",
  "same_as_lead",
  "ImplementingOrganization_type", "ImplementingOrganization_name",
  "ImplementingOrganization_name_2",
  "sector", "scetor_2", "sector_label",
  "activity_type", "activity_type_other", "activity_title", "activity_Status",
  "resource_type", "resource_unit_type", "resource_unit_type_other",
  "URL_to_important_resources",
  "start_date", "end_date",
  "resource_type_other",
  "focal_point_name", "focal_point_email", "focal_point_phone",
  "focal_point_job_title",
  "position", "parish", "community",
  "location_type", "location_type_other", "location_address_comments",
  "quantity_resource", "budget_resource",
  "category_of_people",
  "idp_people_targeted", "idp_women_targeted", "idp_men_targeted",
  "idp_children_targeted",
  "idp_people_reached", "idp_women_reached", "idp_men_reached",
  "idp_children_reached",
  "idp_household_targeted", "idp_household_reached",
  "ndp_people_targeted", "ndp_women_targeted", "ndp_men_targeted",
  "ndp_children_targeted",
  "ndp_people_reached", "ndp_women_reached", "ndp_men_reached",
  "ndp_children_reached",
  "total_population_reached", "category_of_people_specify",
  "hosting_people_targeted", "hosting_women_targeted", "hosting_men_targeted",
  "hosting_children_targeted",
  "hosting_people_reached", "hosting_women_reached", "hosting_men_reached",
  "hosting_children_reached",
  "total_population_targeted",
  "other_people_targeted", "other_women_targeted", "other_men_targeted",
  "other_children_targeted",
  "other_people_reached", "other_women_reached", "other_men_reached",
  "other_children_reached",
  "people_hosting_household_targeted", "people_hosting_household_reached",
  "non_displaced_household_targeted", "non_displaced_household_reached",
  "other_population_household_reached", "other_population_household_targeted",
  "comments"
)

kobo_5w_data <- kobo_5w_data %>%
  rename(
    LeadOrganization_type = any_of("lead_organization_type"),
    LeadOrganization_name = any_of("lead_organization_name"),
    LeadOrganization_name_2 = any_of("lead_organization_name_2"),
    ImplementingOrganization_type = any_of("implementing_organization_type"),
    ImplementingOrganization_name = any_of("implementing_organization_name"),
    ImplementingOrganization_name_2 = any_of("implementing_organization_name_2"),
    activity_Status = any_of("activity_status"),
    URL_to_important_resources = any_of("url_to_important_resources"),
    focal_point_name = any_of("name"),
    focal_point_email = any_of("email"),
    focal_point_phone = any_of("phone"),
    focal_point_job_title = any_of("job_title")
  )

# Add missing columns
missing_cols <- setdiff(reference_columns, names(kobo_5w_data))

if (length(missing_cols) > 0) {
  for (col in missing_cols) {
    kobo_5w_data[[col]] <- NA_character_
  }
}

kobo_5w_data <- kobo_5w_data %>%
  select(all_of(reference_columns))

# Filter WASH sector records
sector_cols <- names(kobo_5w_data)[str_detect(names(kobo_5w_data), regex("sector", ignore_case = TRUE))]

if (length(sector_cols) > 0) {
  initial_rows <- nrow(kobo_5w_data)

  kobo_5w_data <- kobo_5w_data %>%
    filter(if_any(
      all_of(sector_cols),
      ~ str_detect(.x, regex("wash", ignore_case = TRUE))
    ))

  message(glue("Filtered to {nrow(kobo_5w_data)} WASH sector records"))
}

# Normalize parish names
if ("parish" %in% names(kobo_5w_data)) {
  kobo_5w_data <- kobo_5w_data %>%
    mutate(
      parish = str_trim(parish),
      parish = str_replace_all(parish, "(?i)st\\.(?! )", "St. "),
      parish = str_to_title(parish),
      parish = str_replace_all(parish, "St\\.", "St.")
    )
}

# Aggregate parish activity summary
parish_data <- kobo_5w_data %>%
  filter(!is.na(parish), parish != "")

parish_data <- parish_data %>%
  mutate(quantity_resource_num = as.numeric(quantity_resource))

parish_summary <- parish_data %>%
  group_by(parish, activity_type, resource_unit_type) %>%
  summarise(
    n_activities = n(),
    total_quantity = sum(quantity_resource_num, na.rm = TRUE),
    .groups = "drop"
  )

# Calculate total population reached per parish
parish_population <- parish_data %>%
  mutate(total_population_reached_num = as.numeric(total_population_reached)) %>%
  group_by(parish) %>%
  summarise(
    total_population_reached = sum(total_population_reached_num, na.rm = TRUE),
    .groups = "drop"
  )

parish_summary <- parish_summary %>%
  left_join(parish_population, by = "parish")

message(glue("Parish summary created: {n_distinct(parish_summary$parish)} parishes with activities"))

# Add standardized parish names to parish_summary
parish_summary <- parish_summary %>%
  mutate(parish_std = standardize_parish(parish))


# Parish Activity Table Preparation -----

# Step 1: Aggregate by parish and activity (sum across resource_unit_type)
parish_activity_aggregated <- parish_summary %>%
  group_by(parish, parish_std, activity_type) %>%
  summarise(
    total_quantity = sum(total_quantity, na.rm = TRUE),
    .groups = "drop"
  )

# Step 2: Filter to activities with data
activities_with_data <- parish_activity_aggregated %>%
  group_by(activity_type) %>%
  summarise(has_data = any(total_quantity > 0, na.rm = TRUE), .groups = "drop") %>%
  filter(has_data) %>%
  pull(activity_type)

parish_activity_filtered <- parish_activity_aggregated %>%
  filter(activity_type %in% activities_with_data)

# Step 3: Pivot to wide format
parish_activity_wide <- parish_activity_filtered %>%
  pivot_wider(
    names_from = activity_type,
    values_from = total_quantity,
    values_fill = NA
  )

message(glue("Parish activity table prepared: {n_distinct(parish_activity_wide$parish)} parishes, {length(activities_with_data)} activity types"))

# Step 4: Join with NWC data for complete parish coverage
parish_activity_table_data <- parish_activity_wide %>%
  left_join(
    nwc_transformed %>% select(parish, parish_std) %>% distinct(),
    by = "parish_std"
  ) %>%
  mutate(parish = coalesce(parish.y, parish.x, parish_std)) %>%
  select(parish, everything(), -parish.x, -parish.y, -parish_std) %>%
  arrange(parish)


# Activity-to-Icon Mapping -----

# Validate icon files exist
icon_files <- c(
  "wash_assessment.png",
  "hh_water_treatment.png",
  "distribution_hygiene_kits.png",
  "hh_water_distribution.png",
  "hh_water_storage.png",
  "installation_water_storage.png",
  "mobile_water_treatment.png",
  "water_trucking.png",
  "maintenance_water_systems.png",
  "nfi.png",
  "rehabilitation_water_systems.png"
)

missing_icons <- icon_files[!file.exists(here("output", "icons", icon_files))]
if (length(missing_icons) > 0) {
  stop(glue("Missing icon files: {paste(missing_icons, collapse = ', ')}"))
}

# Create activity-to-icon mapping
activity_icon_map <- tibble(
  activity_type = c(
    "WASH Assessment",
    "Distribution of household water treatment material (disinfectant, filters)",
    "Distribution of hygiene kits",
    "HH Water distribution (Bottles, Cases)",
    "HH Water storage (Buckets, Jerrycans)",
    "Installation of Water Storage",
    "Mobile water treatment plant installation",
    "Water trucking",
    "Maintenance of water systems",
    "NFI Distribution (e.g., tarpaulins, solar lamps, blankets, kitchen sets, hygiene kits)",
    "Rehabilitation of water systems"
  ),
  icon_file = icon_files,
  display_label = c(
    "WASH Assessment",
    "HH Water Treatment",
    "Distribution Hygiene Kits",
    "HH Water Distribution",
    "HH Water Storage",
    "Installation Water Storage",
    "Mobile Water Treatment",
    "Water Trucking",
    "Maintenance Water Systems",
    "NFI Distribution",
    "Rehabilitation Water Systems"
  ),
  unit_label = c(
    "#assessments",
    "#treatment units",
    "#kits",
    "#litres",
    "#containers",
    "#installations",
    "#litres / #plants",
    "#litres / #items",
    "#maintenances",
    "#packages",
    "#rehabilitations"
  )
)

# Step 5: Prepare icon mapping for headers
activity_icons <- activity_icon_map %>%
  filter(activity_type %in% activities_with_data) %>%
  select(activity_type, icon_file, display_label, unit_label)


# Create Reactable Table -----

# Helper function to format numbers as K/M
format_k_m <- function(value) {
  if (is.na(value) || value == 0) {
    return("")
  }
  
  abs_value <- abs(value)
  
  if (abs_value >= 1000000) {
    result <- value / 1000000
    return(paste0(round(result, 1), "M"))
  } else if (abs_value >= 1000) {
    result <- value / 1000
    return(paste0(round(result, 1), "K"))
  } else {
    return(as.character(round(value, 1)))
  }
}

# Build column definitions dynamically
column_defs <- list(
  parish = colDef(
    name = "Parish",
    align = "left",
    minWidth = 100,
    style = list(
      fontWeight = "500",
      color = "#333",
      fontSize = "11px"
    )
  )
)

# Add activity columns with icon headers and color gradients
for (act_type in activity_icons$activity_type) {
  # Use local() to properly capture loop variables in closures
  local({
    # Capture icon info for this activity
    act_type_local <- act_type
    icon_info <- activity_icons %>% filter(activity_type == act_type_local)
    icon_file_val <- icon_info$icon_file
    display_label_val <- icon_info$display_label
    unit_label_val <- icon_info$unit_label

    # Get column values for gradient calculation
    col_values <- parish_activity_table_data[[act_type_local]]
    col_max <- max(col_values, na.rm = TRUE)

    column_defs[[act_type_local]] <<- colDef(
      name = act_type_local,
      html = TRUE,
      header = function(value) {
        tags$div(
          style = "text-align: center;",
          tags$img(
            src = glue("./icons/{icon_file_val}"),
            width = "20",
            height = "20",
            title = display_label_val,
            style = "display: block; margin: 0 auto;"
          ),
          tags$div(
            style = "font-size: 8px; margin-top: 2px; line-height: 1.2;",
            unit_label_val
          )
        )
      },
      align = "center",
      minWidth = 70,
      cell = function(value) {
        if (is.na(value) || value == 0) {
          ""
        } else {
          format_k_m(value)
        }
      },
      style = function(value) {
        if (is.na(value) || value == 0 || is.na(col_max) || col_max == 0) {
          list(background = "transparent")
        } else {
          normalized <- value / col_max
          rgb_val <- colorRamp(c("white", "#00BBBB"))(normalized)
          bg_color <- rgb(rgb_val[1], rgb_val[2], rgb_val[3], maxColorValue = 255)

          list(
            fontWeight = "bold",
            background = bg_color,
            borderRadius = "15px",
            padding = "6px 2px",
            display = "inline-block",
            minWidth = "40px",
            textAlign = "center"
          )
        }
      }
    )
  })
}

# Create reactable object
parish_activity_reactable <- reactable(
  parish_activity_table_data,
  columns = column_defs,
  defaultPageSize = nrow(parish_activity_table_data),
  compact = TRUE,
  borderless = FALSE,
  striped = FALSE,
  highlight = TRUE,
  theme = reactableTheme(
    style = list(
      fontFamily = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif",
      fontSize = "9px"
    ),
    cellStyle = list(
      display = "flex",
      flexDirection = "column",
      justifyContent = "center"
    ),
    headerStyle = list(
      fontSize = "11px",
      #fontWeight = "600",
      fontWeight = "bold",
      textTransform = "uppercase",
      letterSpacing = "0.5px",
      color = "#666"
    )
  )
)

message("Parish activity reactable created")


# Data Integration -----

# Filter out "Other" activity type
parish_summary <- parish_summary %>%
  filter(activity_type != "Other")

# Clean organization names to extract acronyms and remove extra text
clean_organization_name <- function(names) {
  # Vectorized function to handle NA and empty strings
  cleaned <- case_when(
    is.na(names) | names == "" ~ names,
    # Extract acronym before " - " if present
    str_detect(names, " - ") ~ str_extract(names, "^[^-]+") %>% str_trim(),
    # Otherwise use the name as-is
    TRUE ~ names
  )
  
  # Remove text in parentheses (vectorized)
  cleaned <- str_remove_all(cleaned, "\\s*\\([^)]+\\)") %>% str_trim()
  
  # Truncate if still too long (vectorized)
  cleaned <- str_trunc(cleaned, width = 40, ellipsis = "...")
  
  return(cleaned)
}

# Create parish-level activity icon list
parish_activities <- parish_summary %>%
  left_join(activity_icon_map, by = "activity_type") %>%
  group_by(parish_std) %>%
  summarise(
    activity_icons = list(unique(icon_file)),
    .groups = "drop"
  )

# Create parish activity presence data with complete parish coverage
parish_activity_presence_data <- parish_activities %>%
  left_join(
    nwc_transformed %>% select(parish, parish_std) %>% distinct(),
    by = "parish_std"
  ) %>%
  mutate(parish = coalesce(parish, parish_std)) %>%
  select(parish, parish_std, activity_icons) %>%
  arrange(parish)

message(glue("Parish activity presence data created: {nrow(parish_activity_presence_data)} parishes with activity data"))


# Partner-Activity Aggregation for Tooltips -----

# Create partner-activity aggregation for tooltip display
parish_partner_activities <- kobo_5w_data %>%
  # Filter out "Other" activities
  filter(activity_type != "Other") %>%
  
  # Create partner name
  mutate(
    # Clean organization names first
    lead_clean = clean_organization_name(LeadOrganization_name),
    impl_clean = clean_organization_name(ImplementingOrganization_name),
    
    # Combine cleaned names
    partner_name = case_when(
      is.na(lead_clean) | lead_clean == "" ~ "Unknown Organization",
      is.na(impl_clean) | impl_clean == "" ~ lead_clean,
      lead_clean == impl_clean ~ lead_clean,
      TRUE ~ paste(lead_clean, impl_clean, sep = " - ")
    ),
    # Standardize parish names
    parish_std = standardize_parish(parish)
  ) %>%
  select(-lead_clean, -impl_clean) %>%
  
  # Join with activity icons
  left_join(activity_icon_map, by = "activity_type") %>%
  
  # Group by parish and partner, collect unique icons
  group_by(parish_std, partner_name) %>%
  summarise(activity_icons = list(unique(icon_file)), .groups = "drop") %>%
  
  # Sort partners alphabetically
  arrange(parish_std, partner_name) %>%
  
  # Nest into parish-level structure
  group_by(parish_std) %>%
  summarise(
    partner_activities = list(tibble(
      partner = partner_name,
      icons = activity_icons
    )),
    .groups = "drop"
  )

# Validation messages
n_partners <- parish_partner_activities %>%
  unnest(partner_activities) %>%
  distinct(partner) %>%
  nrow()

message(glue("Partner-activity aggregation: {n_partners} unique partners across {nrow(parish_partner_activities)} parishes"))

# Check for unknown organizations
unknown_count <- parish_partner_activities %>%
  unnest(partner_activities) %>%
  filter(partner == "Unknown Organization") %>%
  nrow()

if (unknown_count > 0) {
  warning(glue("{unknown_count} partner records have missing organization names"))
}


# Create Parish Activity Presence Reactable -----

# Pre-compute icon-to-label lookup for efficient cell rendering
icon_label_lookup <- activity_icon_map %>%
  select(icon_file, display_label) %>%
  deframe()  # Creates named vector for O(1) lookup

# Build column definitions
parish_presence_columns <- list(
  parish = colDef(
    name = "Parish",
    align = "left",
    minWidth = 40,
    style = list(
      fontWeight = "500",
      color = "#333",
      fontSize = "11px"
    )
  ),
  activity_icons = colDef(
    name = "Activities",
    html = TRUE,
    align = "left",
    cell = function(value) {
      # Handle empty/NA cases
      if (is.null(value) || length(value) == 0) {
        return("")
      }

      # Create img tags for each icon
      icon_tags <- lapply(value, function(icon_file) {
        tags$img(
          src = glue("./icons/{icon_file}"),
          width = "20",
          height = "20",
          title = icon_label_lookup[icon_file],  # Direct O(1) lookup
          style = "margin: 0 10px; vertical-align: middle;"
        )
      })

      tagList(icon_tags)
    }
  )
)

# Create reactable
parish_activity_presence_reactable <- reactable(
  parish_activity_presence_data %>% select(parish, activity_icons),
  columns = parish_presence_columns,
  defaultPageSize = nrow(parish_activity_presence_data),
  compact = TRUE,
  borderless = FALSE,
  striped = FALSE,
  highlight = TRUE,
  theme = reactableTheme(
    style = list(
      fontFamily = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif",
      fontSize = "11px"
    ),
    headerStyle = list(
      fontSize = "11px",
      fontWeight = "bold",
      #fontWeight = "600",
      textTransform = "uppercase",
      letterSpacing = "0.5px",
      color = "#666"
    )
  )
)

message("Parish activity presence reactable created")

# Partner-Parish Activity Table Preparation -----

# Step 1: Unnest parish_partner_activities to flat structure
partner_parish_flat <- parish_partner_activities %>%
  unnest(partner_activities) %>%
  select(parish_std, partner, icons)

message(glue("Partner-parish flat data: {nrow(partner_parish_flat)} partner-parish combinations"))

# Step 2: Extract unique partners and parishes (sorted alphabetically)
unique_partners <- partner_parish_flat %>%
  distinct(partner) %>%
  arrange(partner) %>%
  pull(partner)

unique_parishes <- partner_parish_flat %>%
  distinct(parish_std) %>%
  arrange(parish_std) %>%
  pull(parish_std)

# Step 3: Handle potential duplicate partner names
unique_partners <- make.unique(unique_partners, sep = " ")
partner_parish_flat <- partner_parish_flat %>%
  group_by(partner) %>%
  mutate(partner = make.unique(partner, sep = " ")[1]) %>%
  ungroup()

# Step 4: Pivot to wide format (partners as rows, parishes as columns)
partner_parish_wide <- partner_parish_flat %>%
  pivot_wider(
    names_from = parish_std,
    values_from = icons
  ) %>%
  arrange(partner)

message(glue("Partner-parish wide table: {nrow(partner_parish_wide)} partners × {length(unique_parishes)} parishes"))

# Create Partner-Parish Reactable -----

# Build column definitions
partner_parish_columns <- list(
  partner = colDef(
    name = "Partner",
    align = "left",
    minWidth = 150,
    style = list(
      fontWeight = "500",
      color = "#333",
      fontSize = "11px",
      fontWeight = "bold"
    )
  )
)

# Add parish columns with icon rendering
for (parish in unique_parishes) {
  # Use local() to capture loop variable in closure
  local({
    parish_local <- parish

    partner_parish_columns[[parish_local]] <<- colDef(
      name = parish_local,
      html = TRUE,
      align = "center",
      minWidth = 200,
      cell = function(value) {
        # Handle empty cells
        if (is.null(value) || length(value) == 0) {
          return("")
        }

        # Create img tags for each icon
        icon_tags <- lapply(value, function(icon_file) {
          tags$img(
            src = glue("./icons/{icon_file}"),
            width = "20",
            height = "20",
            title = icon_label_lookup[icon_file],  # Activity name tooltip
            style = "margin: 0 4px; vertical-align: middle;"
          )
        })

        tagList(icon_tags)
      }
    )
  })
}

message(glue("Partner-parish columns defined: {length(partner_parish_columns)} columns (1 partner + {length(unique_parishes)} parishes)"))

# Create reactable object
partner_parish_reactable <- reactable(
  partner_parish_wide,
  columns = partner_parish_columns,
  defaultPageSize = nrow(partner_parish_wide),
  compact = TRUE,
  borderless = FALSE,
  striped = FALSE,
  highlight = TRUE,
  theme = reactableTheme(
    style = list(
      fontFamily = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif",
      fontSize = "11px"
    ),
    headerStyle = list(
      fontSize = "11px",
      #fontWeight = "600",
      fontWeight = "bold",
      textTransform = "uppercase",
      letterSpacing = "0.5px",
      color = "#666"
    )
  )
)

message("Partner-parish reactable created")

# Full join NWC and activity data
parish_integrated <- nwc_transformed %>%
  full_join(parish_activities, by = "parish_std") %>%
  mutate(
    # Use original parish name, fallback to standardized
    parish_display = coalesce(parish, parish_std)
  )

# Report matching statistics
nwc_only <- sum(!is.na(parish_integrated$parish) & is.na(parish_integrated$activity_icons))
activities_only <- sum(is.na(parish_integrated$parish) & !is.na(parish_integrated$activity_icons))
both <- sum(!is.na(parish_integrated$parish) & !is.na(parish_integrated$activity_icons))

message(glue(
  "Parish integration: {both} with both datasets, ",
  "{nwc_only} NWC only, {activities_only} activities only"
))


# Spatial Data Preparation -----

# Load parish boundaries
parish_boundaries <- st_read(
  paste0("/vsizip/", gis_data_path),
  layer = "jam_admn_ad1_py_s1_odpem_pp_parish_20251106",
  quiet = TRUE
)

# Standardize parish names in boundaries
parish_boundaries <- parish_boundaries %>%
  mutate(parish_std = standardize_parish(PARISH))

# Join with integrated data using p-code
parish_boundaries_pcode <- parish_boundaries %>%
  left_join(
    parish_integrated,
    by = c("ADM1_PCODE" = "adm1_pcode"),
    suffix = c("", "_int")
  )

# For parishes without p-code match, try name-based join
parish_boundaries_name <- parish_boundaries %>%
  left_join(
    parish_integrated,
    by = "parish_std",
    suffix = c("", "_int")
  )

# Combine: use p-code match where available, otherwise use name match
parish_boundaries <- parish_boundaries_pcode %>%
  mutate(
    parish = coalesce(parish, parish_boundaries_name$parish),
    percentage_affected = coalesce(percentage_affected, parish_boundaries_name$percentage_affected),
    affected_ind = coalesce(affected_ind, parish_boundaries_name$affected_ind),
    number_of_affected_customers = coalesce(number_of_affected_customers, parish_boundaries_name$number_of_affected_customers),
    activity_icons = map2(
      activity_icons,
      parish_boundaries_name$activity_icons,
      ~ if (is.null(.x)) .y else .x
    ),
    parish_display = coalesce(parish_display, parish_boundaries_name$parish_display, PARISH)
  )

# Clean up temporary columns
parish_boundaries <- parish_boundaries %>%
  select(-ends_with("_int"))

# Join with partner-activity data for tooltips
parish_boundaries <- parish_boundaries %>%
  left_join(parish_partner_activities, by = "parish_std")


# Leaflet Map Creation -----

# Create color palette for choropleth
pal_affected <- colorNumeric(
  palette = c("#FFEDA0", "#FEB24C", "#FC4E2A", "#E31A1C", "#B10026"),
  domain = parish_boundaries$percentage_affected,
  na.color = "#d3d3d3"
)

# Generate tooltip HTML for each parish
parish_boundaries <- parish_boundaries %>%
  mutate(
    tooltip_html = pmap(
      list(parish_display, affected_ind, percentage_affected, partner_activities),
      function(parish_name, affected, pct_affected, partners) {
        html_parts <- "<div style='text-align: left; min-width: 200px;'>"
        
        # Centered header with parish name
        html_parts <- paste0(html_parts, 
          "<div style='text-align: center;'>",
          glue("<b>{parish_name}</b><br/>"))
        
        # Add NWC stats if available
        if (!is.na(affected) && !is.na(pct_affected)) {
          html_parts <- paste0(html_parts,
            glue("<span style='font-size: 11px;'>Affected: {comma(affected)} people ({round(pct_affected * 100, 1)}%)</span>"))
        }
        
        html_parts <- paste0(html_parts, "</div>")
        
        # Add partner activities if available
        if (!is.null(partners) && nrow(partners) > 0) {
          html_parts <- paste0(html_parts, "<div style='margin-top: 10px;'>")
          
          # Iterate through partners
          for (i in 1:nrow(partners)) {
            partner_name <- partners$partner[i]
            icons <- partners$icons[[i]]
            
            html_parts <- paste0(html_parts, 
              "<div style='margin-bottom: 4px; white-space: nowrap;'>")
            html_parts <- paste0(html_parts, glue("<b>{partner_name}:</b> "))
            
            # Add icon images
            if (length(icons) > 0) {
              icon_html <- map_chr(icons, ~ glue(
                "<img src='./icons/{.x}' width='20' height='20' style='margin: 0 2px; vertical-align: middle;'/>"
              ))
              html_parts <- paste0(html_parts, paste(icon_html, collapse = ""))
            }
            
            html_parts <- paste0(html_parts, "</div>")
          }
          
          html_parts <- paste0(html_parts, "</div>")
        }
        
        html_parts <- paste0(html_parts, "</div>")
        return(HTML(html_parts))
      }
    )
  )

# Calculate centroids for bubbles (after tooltip_html is created)
parish_centroids <- parish_boundaries %>%
  st_centroid() %>%
  mutate(
    lon = st_coordinates(.)[, 1],
    lat = st_coordinates(.)[, 2]
  ) %>%
  filter(!is.na(affected_ind) & affected_ind > 0)

# Set white background for map
map_background <- tags$style(".leaflet-container { background: white; }")

# Build leaflet map
parish_map <- leaflet() %>%
  # Layer 1: Choropleth polygons
  addPolygons(
    data = parish_boundaries,
    fillColor = ~pal_affected(percentage_affected),
    fillOpacity = 0.8,
    color = "black",
    weight = 1,
    label = ~tooltip_html,
    highlightOptions = highlightOptions(
      color = "black",
      weight = 3,
      bringToFront = FALSE
    )
  ) %>%
  # Layer 2: Proportional circle markers
  addCircleMarkers(
    data = parish_centroids,
    lng = ~lon,
    lat = ~lat,
    radius = ~sqrt(affected_ind) / 5,
    color = col_border,
    fillColor = col_bubble,
    fillOpacity = 0.9,
    weight = 3,
    label = ~tooltip_html
  ) %>%
  # Layer 3: Static numeric labels
  addLabelOnlyMarkers(
    data = parish_centroids,
    lng = ~lon,
    lat = ~lat,
    label = ~comma(affected_ind, accuracy = 1),
    labelOptions = labelOptions(
      noHide = TRUE,
      direction = "center",
      textOnly = TRUE,
      style = list(
        "color" = "white",
        "font-family" = "Arial, sans-serif",
        "font-weight" = "bold",
        "font-size" = "11px",
        "text-shadow" = "1px 1px 2px rgba(0,0,0,0.5)"
      )
    )
  ) %>%
  # Layer 4: Percentage affected legend
  addLegend(
    position = "topright",
    pal = pal_affected,
    values = parish_boundaries$percentage_affected[!is.na(parish_boundaries$percentage_affected)],
    title = HTML("% Households<br/>Affected"),
    labFormat = labelFormat(
      suffix = "%",
      transform = function(x) x * 100
    ),
    opacity = 0.8
  ) %>%
  # Set map view
  setView(lng = -77.5, lat = 18.1, zoom = 9) %>%
  htmlwidgets::prependContent(map_background)

# Create enhanced legend with activity icons
legend_html <- tags$div(
  style = "background: white; padding: 10px; border: 2px solid rgba(0,0,0,0.2); border-radius: 5px;",

  tags$div(style = "font-weight: bold; margin-bottom: 8px; font-size: 12px;", "Legend"),

  # Bubble size indicator
  tags$div(
    style = "margin-bottom: 10px;",
    tags$span(
      style = glue("display: inline-block; width: 20px; height: 20px; ",
                   "background-color: {col_bubble}; border-radius: 50%; ",
                   "border: 2px solid {col_border}; margin-right: 6px;")
    ),
    tags$span(style = "font-size: 12px;", "Affected Individuals (bubble size)")
  ),

  # Activity icons - single column
  tags$div(
    style = "line-height: 1.6;",
    tags$div(style = "font-weight: bold; margin-bottom: 5px; font-size: 12px;", "Activity Types:"),
    pmap(activity_icon_map, function(icon_file, display_label, ...) {
      tags$div(
        style = "margin-bottom: 5px;",
        tags$img(src = glue("./icons/{icon_file}"), width = "20", height = "20",
                 style = "vertical-align: middle; margin-right: 5px;"),
        tags$span(style = "font-size: 11px;", display_label)
      )
    })
  )
)

# Add custom legend to map
parish_map <- parish_map %>%
  addControl(html = legend_html, position = "bottomleft")


# Dashboard Rendering -----

# Calculate summary statistics
summary_stats <- parish_integrated %>%
  summarise(
    total_affected_ind = sum(affected_ind, na.rm = TRUE),
    total_affected_customers = sum(number_of_affected_customers, na.rm = TRUE),
    parishes_affected = sum(!is.na(affected_ind)),
    avg_percentage_affected = mean(percentage_affected, na.rm = TRUE),
    parishes_with_activities = sum(!is.na(activity_icons)),
    total_partners = n_partners
  )

message(glue(
  "Dashboard data prepared: {summary_stats$parishes_affected} parishes with NWC data, ",
  "{summary_stats$parishes_with_activities} parishes with activities"
))

# Package data for dashboard
dashboard_data <- list(
  transformed = nwc_transformed,
  parish_map = parish_map,
  parish_activity_table = parish_activity_reactable,
  parish_activity_table_data = parish_activity_table_data,
  parish_activity_presence_table = parish_activity_presence_reactable,
  partner_parish_table = partner_parish_reactable,
  summary_stats = summary_stats
)

# Render dashboard
render(
  input = here("nwc-parish-dashboard.Rmd"),
  output_dir = here("output"),
  output_file = "nwc-parish-dashboard",
  params = list("data" = dashboard_data),
  envir = new.env(parent = globalenv())
)

message(glue("Integrated dashboard rendered to: {here('output', 'nwc-parish-dashboard.html')}"))
