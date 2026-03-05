library(tidyverse)
library(readxl)
library(writexl)

# Read Excel file to get column names
columns <- read_excel('output/20260206_wash_survey_hh_level.xlsx', n_max = 1) %>%
  names()

# Classification function
classify_column <- function(col_name) {
  col_lower <- str_to_lower(col_name)

  # Metadata/Admin
  if (col_name %in% c('index', 'name_of_the_organization', 'camp_name')) {
    return('Metadata')
  }

  # Follow-ups
  if (str_starts(col_lower, 'if_|specify_|comment|please_specify')) {
    return('Follow-up')
  }

  # Demographics
  if (str_detect(col_lower, 'age_|sex_|gender_|marital_|education_|total_no_|number_of_')) {
    return('Demographics')
  }

  # Boolean indicators (options)
  if (str_ends(col_lower, '_yes|_no|_dk|_refused|_other')) {
    return('Option')
  }

  # Check for option keywords
  option_keywords <- c('less_than', 'more_than', 'between', 'domestic', 'drinking',
                      'cooking', 'washing', 'bathing', 'protected', 'unprotected',
                      'treated', 'untreated', 'piped', 'well', 'borehole',
                      'tanker', 'surface')

  for (keyword in option_keywords) {
    if (str_ends(col_lower, paste0(keyword, 's?'))) {
      return('Option')
    }
  }

  # Main survey questions
  if (str_detect(col_lower, '^hh_(ws|wq|s|swm|h|fc)_\\d+')) {
    return('Main Question')
  }

  return('Main Question')
}

# Label creation function
create_suggested_label <- function(col_name, col_type) {
  # Metadata - simple names
  if (col_type == 'Metadata') {
    mapping <- c(
      'index' = 'ID',
      'name_of_the_organization' = 'Organization',
      'camp_name' = 'Camp'
    )
    return(ifelse(!is.na(mapping[col_name]),
                  mapping[col_name],
                  str_to_title(str_replace_all(col_name, '_', ' '))))
  }

  label <- col_name

  # Remove common prefixes
  label <- str_remove(label, '^hh_(ws|wq|s|swm|h|fc)_\\d+_\\d+_?')
  label <- str_remove(label, '^hh_(ws|wq|s|swm|h|fc)_\\d+_')

  # Remove "if_other" and "please" patterns
  label <- str_remove(label, '^if_other_please_')
  label <- str_remove(label, '^if_other_')
  label <- str_remove(label, '^if_yes_follow_with_the_list_')
  label <- str_remove(label, '^please_specify_?')

  # Common phrase shortenings
  replacements <- list(
    'does_your_household' = 'HH',
    'your_household' = 'HH',
    'household' = 'HH',
    'in_the_last_30_days' = '(30d)',
    'in_the_last' = '(last',
    'if_applicable' = '',
    'waterpoints' = 'water points',
    'less_than' = '<',
    'more_than' = '>',
    'greater_than' = '>',
    '_min' = 'min',
    '_minutes' = 'min',
    '_hours' = 'hr',
    '_days' = 'd',
    'number_of' = 'no.',
    'total_no_of' = 'total',
    'age_of' = 'age',
    'respondent' = 'resp.'
  )

  for (i in seq_along(replacements)) {
    old_text <- names(replacements)[i]
    new_text <- replacements[[i]]
    label <- str_replace_all(label, fixed(old_text), new_text)
  }

  # Replace underscores with spaces
  label <- str_replace_all(label, '_', ' ')

  # Remove extra spaces
  label <- str_squish(label)

  # Capitalize first letter
  if (nchar(label) > 0) {
    label <- paste0(str_to_upper(str_sub(label, 1, 1)), str_sub(label, 2))
  }

  # Limit length for chart axes
  if (nchar(label) > 50) {
    words <- str_split(label, ' ')[[1]]
    if (length(words) > 6) {
      label <- paste(c(words[1:6], '...'), collapse = ' ')
    }
  }

  return(label)
}

# Create analysis dataframe
header_analysis <- tibble(
  current_name = columns
) %>%
  mutate(
    type = map_chr(current_name, classify_column),
    suggested_label = map2_chr(current_name, type, create_suggested_label)
  )

# Save to Excel
write_xlsx(header_analysis, 'output/header_analysis.xlsx')

message(glue::glue("Created header analysis with {nrow(header_analysis)} columns"))
message("Output: output/header_analysis.xlsx")
