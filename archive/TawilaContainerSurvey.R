# ============================================================

library(tidyverse)
library(readxl)
library(janitor)

# -------------------------------
# 1. Load & Clean Data
# -------------------------------
#file <- "C:/Users/Lenovo/Downloads/Tawila Survey Analysis 2026/3.Exploration and preparation/1.Cleaning/20260210_wash_survey_hh_container_level.xlsx - container.xlsx"
file <- "data/20260210_wash_survey_hh_container_level.xlsx - container.xlsx"

df <- read_excel(file) %>% clean_names()

# Rename essential columns
df <- df %>%
  rename(
    household_id = parent_index,
    number = number_of_containers,
    household_size = total_no_of_people_in_hh
  )

# -------------------------------
# 2. Normalize Fill Fraction
# -------------------------------
df <- df %>%
  mutate(
    fill_fraction = case_when(
      str_detect(as.character(fill_level), "3/4|¾") ~ 0.75,
      str_detect(as.character(fill_level), "1/2|½") ~ 0.5,
      str_detect(as.character(fill_level), "1/4|¼") ~ 0.25,
      TRUE ~ suppressWarnings(as.numeric(fill_level))
    ),
    fill_fraction = if_else(is.na(fill_fraction), 1, fill_fraction)  # assume full
  )

# -------------------------------
# 3. Convert Frequency to Per-Day
# -------------------------------
df <- df %>%
  mutate(
    frequency_per_day = case_when(
      str_detect(frequency_filled, regex("twice|مرتين|2|٢", ignore_case=TRUE)) ~ 2,
      str_detect(frequency_filled, regex("three|ثلاث|٣", ignore_case=TRUE)) ~ 3,
      str_detect(frequency_filled, regex("four|اربعة|أربعة|٤", ignore_case=TRUE)) ~ 4,
      str_detect(frequency_filled, regex("five|خمسة|٥", ignore_case=TRUE)) ~ 5,
      str_detect(frequency_filled, regex("six|ستة|٦", ignore_case=TRUE)) ~ 6,
      str_detect(frequency_filled, regex("once|مرة|1|١", ignore_case=TRUE)) ~ 1,
      str_detect(frequency_filled, regex("every two|two days", ignore_case=TRUE)) ~ 0.5,
      str_detect(frequency_filled, regex("daily|يوميا", ignore_case=TRUE)) ~ 1,
      TRUE ~ 1  # fallback
    )
  )

# -------------------------------
# 4. Remove Unrealistic Volume Outliers
# -------------------------------
df <- df %>%
  mutate(
    volume_liters = suppressWarnings(as.numeric(volume_liters)),
    volume_liters = if_else(volume_liters > 300, NA_real_, volume_liters)
  )

# -------------------------------
# 5. Assign Use Type: Drinking / Domestic / Both
# -------------------------------
df <- df %>%
  mutate(
    use_type = case_when(
      str_detect(container_use, "Drinking") & str_detect(container_use, "Domestic") ~ "Both",
      str_detect(container_use, "Drinking") ~ "Drinking",
      str_detect(container_use, "Domestic") ~ "Domestic",
      TRUE ~ "Other"
    )
  )

# -------------------------------
# 6. Calculate Daily Liters per Container
# -------------------------------
df <- df %>%
  mutate(
    daily_liters = volume_liters * number * fill_fraction * frequency_per_day
  )

# -------------------------------
# 7. Aggregate to Household Level
# -------------------------------
hh <- df %>%
  group_by(household_id, household_size) %>%
  summarise(
    drinking_l = sum(daily_liters[use_type %in% c("Drinking", "Both")], na.rm=TRUE),
    domestic_l = sum(daily_liters[use_type %in% c("Domestic", "Both")], na.rm=TRUE),
    total_l = drinking_l + domestic_l,
    .groups = "drop"
  ) %>%
  mutate(
    lpd_per_person = total_l / household_size
  )

# -------------------------------
# 8. Summary Statistics
# -------------------------------
summary_stats <- hh %>%
  summarise(
    mean_lpd = mean(lpd_per_person, na.rm=TRUE),
    median_lpd = median(lpd_per_person, na.rm=TRUE),
    min_lpd = min(lpd_per_person, na.rm=TRUE),
    max_lpd = max(lpd_per_person, na.rm=TRUE),
    p25 = quantile(lpd_per_person, 0.25, na.rm=TRUE),
    p75 = quantile(lpd_per_person, 0.75, na.rm=TRUE)
  )

print(summary_stats)

# -------------------------------
# 9. Visualizations
# -------------------------------

# Histogram — WHO 15 L/p/d Line
ggplot(hh, aes(lpd_per_person)) +
  geom_histogram(binwidth=5, fill="steelblue", color="white") +
  geom_vline(xintercept=15, color="red", size=1.2, linetype="dashed") +
  annotate("text", x=17, y=30, label="WHO Minimum 15 L/p/d", color="red") +
  theme_minimal() +
  labs(
    title = "Distribution of Liters Per Person Per Day (L/p/d)",
    x = "L/p/d",
    y = "Number of Households"
  )

# Boxplot
ggplot(hh, aes(y=lpd_per_person)) +
  geom_boxplot(fill="lightgreen") +
  theme_minimal() +
  labs(title="LPD Distribution Across Households", y="L/p/d")

# LPD vs Household Size
ggplot(hh, aes(household_size, lpd_per_person)) +
  geom_point(alpha=0.4) +
  geom_smooth(method="loess") +
  theme_minimal() +
  labs(
    title="Relationship Between Household Size and L/p/d",
    x="Household Size",
    y="L/p/d"
  )


# Camp level analysis
hh_camp <- df %>%
  select(household_id, household_size, camp_name, daily_liters, use_type) %>%
  group_by(household_id, household_size, camp_name) %>%
  summarise(
    drinking_l = sum(daily_liters[use_type %in% c("Drinking", "Both")], na.rm=TRUE),
    domestic_l = sum(daily_liters[use_type %in% c("Domestic", "Both")], na.rm=TRUE),
    total_l = drinking_l + domestic_l,
    .groups = "drop"
  ) %>%
  mutate(
    lpd_per_person = total_l / household_size
  )

ggplot(hh_camp, aes(x = reorder(camp_name, lpd_per_person),
                    y = lpd_per_person)) +
  stat_summary(fun = mean, geom="bar", fill="steelblue") +
  stat_summary(fun.data = mean_cl_normal, geom="errorbar", width=0.2) +
  theme_minimal() +
  labs(
    title = "Average Liters Per Person Per Day by Camp",
    x = "Camp",
    y = "Average L/p/d"
  ) +
  coord_flip()

# highlights which camps are critically low L/p/d

# Boxplot: L/p/d Distribution by Camp
ggplot(hh_camp, aes(x = camp_name, y = lpd_per_person, fill = camp_name)) +
  geom_boxplot(alpha = 0.7) +
  theme_minimal() +
  labs(
    title = "Distribution of L/p/d by Camp",
    x = "Camp", 
    y = "L/p/d"
  ) +
  theme(axis.text.x = element_text(angle=45, hjust=1),
        legend.position="none")

#Shows median, IQR, and extreme cases per camp.


# Drinking vs Domestic Water Availability by Camp

camp_use <- hh_camp %>%
  group_by(camp_name) %>%
  summarise(
    avg_drinking = mean(drinking_l, na.rm=TRUE),
    avg_domestic = mean(domestic_l, na.rm=TRUE)
  ) %>%
  pivot_longer(cols = c(avg_drinking, avg_domestic),
               names_to = "type",
               values_to = "liters")

ggplot(camp_use, aes(x = camp_name, y = liters, fill = type)) +
  geom_col(position = "stack") +
  theme_minimal() +
  labs(
    title = "Average Daily Drinking vs Domestic Water by Camp",
    x = "Camp",
    y = "Liters per Household per Day",
    fill = "Water Use"
  ) +
  theme(axis.text.x = element_text(angle=45, hjust=1))

##distinguish camps where domestic water is lacking 

# Number of Households Surveyed per Camp

hh_camp %>%
  count(camp_name) %>%
  ggplot(aes(x = reorder(camp_name, n), y = n)) +
  geom_col(fill="darkorange") +
  theme_minimal() +
  labs(
    title = "Number of Surveyed Households by Camp",
    x = "Camp", y = "HH Count"
  ) +
  coord_flip()

#Shows sample sizes

# Camp Ranking Table (optional)

camp_rank <- hh_camp %>%
  group_by(camp_name) %>%
  summarise(
    avg_lpd = mean(lpd_per_person, na.rm=TRUE),
    median_lpd = median(lpd_per_person, na.rm=TRUE),
    hh_count = n()
  ) %>%
  arrange(avg_lpd)

print(camp_rank)

#Produce a sorted table for reporting slides.

# -------------------------------
# 10. Vulnerability Flags to the Household Summary
# -------------------------------

# Extract one row per household with vulnerabilities

vuln <- df %>%
  group_by(household_id) %>%
  summarise(
    under5 = first(do_you_have_members_less_than_5_years_old),
    plw = first(do_you_have_members_with_pregnant_or_lactating_women),
    disabilities = first(no_of_people_with_disabilities_in_hh_optional),
    recent_arrival = first(did_people_arrive_two_weeks_ago_into_tawila),
    .groups = "drop"
  ) %>%
  mutate(
    under5 = if_else(under5 == "Yes", 1, 0),
    plw = if_else(plw == "Yes", 1, 0),
    recent_arrival = if_else(recent_arrival == "Yes", 1, 0),
    disabilities = if_else(is.na(disabilities) | disabilities == 0, 0, 1)  # binary flag
  )

# Merge vulnerabilities into Household L/p/d Summary

hh_vuln <- hh %>%
  left_join(vuln, by = "household_id")


# Vulnerability‑Based L/p/d Disaggregation Plots

## L/p/d for Households WITH vs WITHOUT Under‑5 Children

ggplot(hh_vuln, aes(x = factor(under5), y = lpd_per_person, fill = factor(under5))) +
  geom_boxplot() +
  scale_x_discrete(labels=c("0"="No Under-5", "1"="Has Under-5")) +
  theme_minimal() +
  labs(
    title = "L/p/d Comparison: Households With and Without Under-5 Children",
    x = "Under-5 Presence",
    y = "L/p/d",
    fill = "Under-5"
  )

## L/p/d for Households With PLW

ggplot(hh_vuln, aes(x = factor(plw), y = lpd_per_person, fill = factor(plw))) +
  geom_boxplot() +
  scale_x_discrete(labels=c("0"="No PLW", "1"="Has PLW")) +
  theme_minimal() +
  labs(
    title = "L/p/d Comparison: Households With vs Without Pregnant/Lactating Women",
    x = "PLW Status",
    y = "L/p/d",
    fill = "PLW"
  )

## L/p/d for Households With People With Disabilities

ggplot(hh_vuln, aes(x = factor(disabilities), y = lpd_per_person, fill = factor(disabilities))) +
  geom_boxplot() +
  scale_x_discrete(labels=c("0"="No Disabilities", "1"="One or More")) +
  theme_minimal() +
  labs(
    title = "L/p/d Comparison: Disability vs Non-Disability Households",
    x = "Disability Status",
    y = "L/p/d",
    fill = "Disability"
  )


## L/p/d for Recent Arrivals (past 2 weeks)

ggplot(hh_vuln, aes(x = factor(recent_arrival), y = lpd_per_person, fill = factor(recent_arrival))) +
  geom_boxplot() +
  scale_x_discrete(labels=c("0"="Not Recent Arrival", "1"="Recent Arrival")) +
  theme_minimal() +
  labs(
    title = "L/p/d Comparison: Recent Arrivals vs Long-Term Residents",
    x = "Arrival Status",
    y = "L/p/d",
    fill = "Recent Arrival"
  )

### Summary Table by Vulnerability

vuln_summary <- hh_vuln %>%
  group_by(under5, plw, disabilities, recent_arrival) %>%
  summarise(
    households = n(),
    avg_lpd = mean(lpd_per_person, na.rm=TRUE),
    median_lpd = median(lpd_per_person, na.rm=TRUE),
    .groups = "drop"
  )

print(vuln_summary)

# -------------------------------
# 11. Export Output
# -------------------------------
#write_csv(hh, "C:/Users/Lenovo/Downloads/Tawila Survey Analysis 2026/3.Exploration and preparation/1.Cleaning/tawila_lpd_household_summary.csv")
write_csv(hh, "output/tawila_lpd_household_summary.csv")

