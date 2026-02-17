# Tawila IDP Camp — WASH Clustering Methodology

## 1. Objective

The goal of this analysis was to apply **unsupervised machine learning** to the WASH (Water, Sanitation, and Hygiene) household survey data from Tawila IDP camp in order to identify distinct groups of households that share similar conditions. Unlike supervised learning, where the algorithm learns from labelled examples, unsupervised classification discovers patterns in the data without being told what to look for — making it well suited for exploratory analysis of survey data where we don't know in advance how many groups exist or what defines them.

---

## 2. Data Preparation

### 2.1 Source Data

The input dataset contained **369 household records** with **234 survey variables** collected across four camp sections (Camps A through D) by four humanitarian organisations (IRC, SCI, TGH, SI). The survey covered five WASH domains: water supply, water quality, sanitation, solid waste management, and hygiene.

### 2.2 Feature Selection

Of the 234 columns, many were free-text fields, "if other, specify" follow-ups, or highly sparse conditional questions (e.g., only answered by the 23 households that used a specific water treatment method). Including these would introduce noise — variables with mostly empty values that don't meaningfully differentiate households.

**60 raw features were selected** across five domains:

- **Demographics (14 features):** household size, composition by age/gender, head of household gender, vulnerability indicators (children under 5, pregnant/lactating women, malnutrition treatment, disabilities), and new arrival status.
- **Water supply (24 features):** primary water source, sufficiency for drinking and domestic use, water access problems (binary flags for each problem type), time to fetch water, water coping strategies, number of containers, water treatment methods, and litres per day.
- **Sanitation (11 features):** type of sanitation facility, shared facilities, sanitation problems, safety at latrines, open defecation observations, latrine damage, and visible faeces.
- **Solid waste management (4 features):** garbage disposal methods.
- **Hygiene (7 features):** hygiene item problems, handwashing device type, soap availability, hygiene satisfaction, spending, and primary WASH concern.

**After encoding and feature engineering** (Section 2.3-2.5), the final feature matrix contained approximately **67-69 features**, depending on the number of one-hot encoded concern categories. hygiene item problems, handwashing device type, soap availability, hygiene satisfaction, spending, and primary WASH concern.

### 2.3 Encoding

Clustering algorithms work with numbers, not text, so categorical responses had to be converted:

- **Binary yes/no questions** were mapped to 1/0.
- **Ordinal variables** (e.g., hygiene satisfaction from "very unsatisfied" to "very satisfied") were mapped to ordered integers (0–4).
- **Multi-select questions** (already one-hot encoded as separate binary columns in the source data) were kept as-is.
- **The primary water source** was converted to a binary "improved vs. unimproved" flag following WHO/UNICEF JMP classification.
- **The biggest WASH concern** was one-hot encoded (each concern became its own 0/1 column).

### 2.4 Missing Values

Missing values were handled according to their nature:

- **Conditional binary flags** (e.g., "which water problems do you have?" — only asked of those who answered "yes" to having problems): filled with 0, since a missing value means the household didn't report that problem.
- **Continuous variables** (containers observed, litres per day): filled with the median to avoid distortion from outliers.

### 2.5 Engineered Features

Several composite features were created to capture higher-level patterns:

- **Litres per person per day (L/p/d):** total household litres divided by household size — the standard WASH metric for water adequacy (Sphere minimum: 15 L/p/d).
- **Children ratio:** proportion of household members under 18.
- **Vulnerability score (0–4):** sum of four binary indicators — has children under 5, has pregnant/lactating women, has child in malnutrition treatment, has members with disabilities.
- **Water coping count:** number of negative coping strategies adopted for water scarcity.
- **Sanitation environment risk:** sum of three environmental indicators — open defecation observed, visible faeces, and latrine damaged/full.

**Final feature matrix:** Starting with 60 raw features, encoding transformations (primary water source → binary improved flag, biggest WASH concern → one-hot encoded into 3-5 columns) and adding 5 engineered features resulted in approximately **67-69 total features** used for PCA and clustering.

### 2.6 Standardisation

All features were **standardised** (z-score normalisation: subtract the mean, divide by the standard deviation) so that each variable contributes equally to the clustering. Without this, a variable like "total litres per day" (range 0–800) would dominate over a binary variable (range 0–1) simply because of its larger numerical scale.

---

## 3. Dimensionality Reduction — PCA

### 3.1 What PCA Does

**Principal Component Analysis (PCA)** is a technique that transforms a set of correlated variables into a smaller set of uncorrelated "principal components." Each component is a linear combination of the original features, ordered by how much of the total data variation it captures.

Think of it this way: if you had 70 thermometers measuring different parts of a building, many would move together (all rooms warm up when the heating is on). PCA identifies these underlying patterns — the "heating is on" signal — and represents them as single dimensions instead of redundant individual measurements.

### 3.2 Why Use PCA Before Clustering

With 70 features, the data lives in a 70-dimensional space. Clustering in high dimensions suffers from the "curse of dimensionality" — distances between points become less meaningful as dimensions increase, and noise in irrelevant features can obscure genuine structure. PCA addresses this by:

1. **Reducing noise:** Minor components that capture random variation are discarded.
2. **Removing redundancy:** Correlated features (e.g., "enough water for drinking" and "enough water for domestic use") are consolidated.
3. **Improving clustering performance:** Algorithms work better in lower-dimensional spaces where distances are more meaningful.

### 3.3 Results and Interpretation

The PCA analysis of the **~67-69 standardised features** (60 raw features after encoding transformations and feature engineering) produced the following cumulative variance explained:

| Components | Cumulative Variance |
|---|---|
| PC1 | 7.8% |
| PC2 | 13.4% |
| PC3 | 18.4% |
| PC5 | 26.3% |
| PC10 | 41.6% |
| PC20 | ~65% |

**How to read this:** The first principal component captures 7.8% of all variation in the data. The first two together capture 13.4%, and so on. No single component dominates, which tells us the data variation is spread across many dimensions — typical for survey data with diverse question domains.

**Critical methodological detail:** The clustering algorithms (described in Section 4) operate on these **20 principal components**, not the original 70 features. This means K-Means discovers patterns in the **latent PCA space** — the underlying structure captured by the principal components. The cluster assignments are then mapped back to the original features for interpretation (Section 6), allowing us to say "Cluster 0 has lower water access" even though the clustering itself happened on abstract PC1-PC20 scores.

This approach provides the best of both worlds: technical quality (clustering on denoised, decorrelated components in manageable dimensionality) and programmatic relevance (profiles expressed in meaningful WASH indicators).

The PCA scatter plot (PC1 vs PC2) visualises each household as a point in the two most informative dimensions. Even though only 13.4% of variation is shown, the two clusters are visibly separated along the PC1 axis, confirming that the most important dimension of variation in this survey corresponds to the severity of WASH deprivation.

---|---|
| PC1 | 7.8% |
| PC2 | 13.4% |
| PC3 | 18.4% |
| PC5 | 26.3% |
| PC10 | 41.6% |
| PC20 | ~65% |

**How to read this:** The first principal component captures 7.8% of all variation in the data. The first two together capture 13.4%, and so on. No single component dominates, which tells us the data variation is spread across many dimensions — typical for survey data with diverse question domains.

The PCA scatter plot (PC1 vs PC2) visualises each household as a point in the two most informative dimensions. Even though only 13.4% of variation is shown, the two clusters are visibly separated along the PC1 axis, confirming that the most important dimension of variation in this survey corresponds to the severity of WASH deprivation.

---

## 4. Clustering Algorithms

### 4.1 K-Means Clustering

**K-Means** is the primary clustering algorithm used. It operates on the **20-dimensional PCA space** (the principal components from Section 3), not the original 70 features. The algorithm works as follows:

1. **Initialisation:** Choose K random points as initial cluster centres ("centroids") in the 20D PCA space.
2. **Assignment:** Assign each household to the nearest centroid using Euclidean distance between the household's PC1-PC20 scores and each centroid's PC1-PC20 coordinates.
3. **Update:** Move each centroid to the average position of all households assigned to it (computing the mean of PC1-PC20 separately).
4. **Repeat:** Steps 2–3 iterate until assignments stop changing (convergence).

The result is K groups where each household belongs to the cluster whose centre it is closest to **in PCA space**. K-Means is fast, scalable, and tends to produce compact, roughly equally-sized clusters.

**Why this matters:** Clustering on PCA components rather than raw features means the algorithm finds households with similar **latent WASH patterns** (the underlying structure) rather than households that happen to share individual survey responses. This produces more robust, generalizable groups.

**Parameters used:** 50 random initialisations (`n_init=50`) to avoid getting stuck in poor local solutions, with up to 1,000 iterations per run (`max_iter=1000`).

### 4.2 Hierarchical (Agglomerative) Clustering

As a validation method, **agglomerative hierarchical clustering** with Ward linkage was also applied. This algorithm works differently:

1. Start with each household as its own cluster (369 clusters).
2. Merge the two most similar clusters at each step.
3. Repeat until the desired number of clusters is reached.

Ward linkage specifically merges the pair of clusters that produces the smallest increase in total within-cluster variance — similar in spirit to what K-Means optimises.

**Purpose:** If two different algorithms arrive at similar groupings, the structure is more likely to be genuine rather than an artefact of one particular method.

**Result:** K-Means and hierarchical clustering agreed on **86.2% of household assignments**, providing strong confirmation that the two-cluster structure is robust.

---

## 5. Choosing the Number of Clusters (K)

Since the algorithm needs to be told how many clusters to find, three methods were used to determine the optimal K:

### 5.1 Elbow Method (Inertia)

**Inertia** measures the total squared distance from each point to its assigned cluster centre — lower is better, but it always decreases as K increases (with K = 369 you'd get inertia = 0). The "elbow" is where adding more clusters stops producing significant improvement.

In our analysis, the inertia curve showed a clear bend at K=2, with diminishing returns for higher values.

### 5.2 Silhouette Score

The **silhouette score** (range: -1 to +1) measures how well each household fits its assigned cluster compared to the next-best alternative cluster. For each household:

- **(a)** = average distance to all other households in the *same* cluster
- **(b)** = average distance to all households in the *nearest different* cluster
- **Silhouette** = (b − a) / max(a, b)

A score near +1 means the household is well-matched to its cluster and far from others. Near 0 means it sits on the boundary. Negative means it may be misassigned.

**Results:**

| K | Silhouette Score |
|---|---|
| 2 | **0.595** |
| 3 | 0.554 |
| 4 | 0.539 |
| 5 | 0.568 |
| 6 | 0.555 |
| 7 | 0.552 |
| 8 | 0.564 |

**K=2 produced the highest silhouette score (0.595)**, indicating the clearest cluster separation. A silhouette of 0.595 is considered a "reasonable to strong" structure. For context, values above 0.5 are generally interpreted as meaningful clusters, and values above 0.7 indicate very strong structure.

### 5.3 Calinski-Harabasz Index

This index measures the ratio of between-cluster dispersion to within-cluster dispersion — higher is better. While it increased monotonically with K in our data (common when clusters have sub-structure), K=2 was the clear inflection point where the jump was most pronounced relative to the additional complexity.

### 5.4 Decision

**K=2 was selected** based on the highest silhouette score and the elbow in the inertia curve. From an interpretability standpoint, two clusters also aligned with a meaningful humanitarian distinction: households with severe, compounding WASH deprivation versus those with moderate needs.

---

## 6. Cluster Profiling

### 6.1 How Profiles Were Computed

Once every household was assigned to a cluster (based on its position in the 20D PCA space), the **mean value of each original feature was computed within each cluster**. This is the critical step that translates abstract cluster assignments back into interpretable WASH indicators.

**The mapping process:**
1. K-Means assigns household 123 to Cluster 0 because its PC1-PC20 scores are closest to Cluster 0's centroid
2. Profiling then looks up household 123's **original** values: "enough water for drinking = No", "litres per person per day = 8.2", etc.
3. These original values are averaged across all households in Cluster 0
4. Result: "Cluster 0 has 79% with water access problems, 10.5 L/p/d median" (interpretable)

For binary features (0/1), the mean equals the proportion — e.g., a mean of 0.79 on "water access problems" means 79% of that cluster's households reported water access problems.

These means were then compared across clusters to identify which original WASH indicators most differentiate the groups discovered in PCA space.

### 6.2 Statistical Significance Testing

To confirm the differences weren't due to chance, the **Kruskal-Wallis H test** was applied to each feature. This is a non-parametric test (it doesn't assume the data follows a normal distribution) that checks whether at least one group's distribution differs significantly from the others.

A significance threshold of **p < 0.01** was used (meaning less than 1% probability the difference arose by chance). **17 of 22 key indicators** showed statistically significant differences, with the strongest being:

- Sanitation environment risk (H=120.9, p=4.0×10⁻²⁸)
- Water access problems (H=99.8, p=1.7×10⁻²³)
- Sanitation problems (H=83.3, p=7.1×10⁻²⁰)

### 6.3 Visualisations

- **Heatmap:** Each row is a WASH indicator, each column is a cluster. Cells are coloured from red (worse) to green (better), with the actual mean value annotated. This gives an instant visual of which cluster is worse off across the board.
- **Radar chart:** A spider-web plot showing 10 key normalised indicators. The shape of each cluster's polygon reveals its overall profile at a glance.
- **Box plots:** Show the full distribution (median, quartiles, outliers) of continuous variables like litres per person per day, not just the averages.

---

## 7. Geographic Analysis

### 7.1 Post-Hoc Camp Association

After clustering was complete (clusters were derived purely from WASH and demographic indicators, with no camp or organisation information used as input), a **Chi-square test of independence** was performed to check whether cluster membership was associated with camp location.

The Chi-square test compares the observed distribution of clusters across camps against what would be expected if cluster assignment were random. A large Chi-square statistic with a small p-value indicates a strong association.

**Result:** Chi-square = 113.2, p = 2.3×10⁻²⁴ (df = 3). This is overwhelmingly significant — the probability of this camp-cluster association arising by chance is essentially zero. The clusters are geographically concentrated:

| Camp | Organisation | High Vulnerability (C0) | Moderate Needs (C1) |
|---|---|---|---|
| Camp B | SCI | 86% | 14% |
| Camp C | TGH | 84% | 16% |
| Camp A | IRC | 37% | 63% |
| Camp D | SI | 23% | 77% |

### 7.2 Per-Camp Indicator Comparison

To go beyond cluster labels, the same key WASH indicators were computed per camp, confirming that the geographic concentration reflects real differences in conditions (e.g., Camp C has a median of 6.6 L/p/d versus Camp D's 20.0 L/p/d; Camp C has 1.8% with enough soap versus Camp D's 23.6%).

---

## 8. Alternative Analysis — K=3 Clustering

### 8.1 Rationale

While K=2 produced the strongest statistical separation (highest silhouette score), the high-vulnerability cluster contained approximately 53% of all households (196 of 369) and showed variation across multiple WASH domains simultaneously. A follow-up analysis with K=3 was conducted to test whether this large group could be meaningfully subdivided into distinct sub-profiles — potentially revealing different types of deprivation that would warrant different humanitarian responses.

The K=3 silhouette score (0.554) remained well above the 0.5 threshold for meaningful structure, confirming that three clusters still represent a valid grouping of the data.

### 8.2 PCA for K=3

The three-cluster analysis used **the same 20 principal components** as the K=2 analysis. Unlike the K=2 vs K=3 distinction, there was no separate PCA performed — both clustering solutions operate on the identical PCA-reduced space. The K=3 refinement simply asks K-Means to find three centroids instead of two in the same 20-dimensional latent space, revealing sub-structure within the high-vulnerability group that K=2 aggregates together.

This approach ensures consistency: both analyses discover patterns in the same underlying representation of the data, making the cluster profiles directly comparable.

### 8.3 Three-Cluster Profiles

K-Means with K=3 produced three distinct groups:

**Cluster 0 — "Low Need" (159 households, 43.1%)**

These households have the best WASH conditions in the camp. Only 16% report water access problems, 82% have enough water for drinking, and the median water consumption is 21.3 litres per person per day — above the Sphere minimum of 15 L/p/d. Sanitation problems are reported by 25% and open defecation is observed by 20%. Soap availability is the highest of all groups at 22%. This cluster is concentrated in Camp D (60%) and Camp A (33%).

**Cluster 1 — "Sanitation Crisis" (65 households, 17.6%)**

This is the smallest but most distinctly profiled group, defined primarily by extreme sanitation deprivation. 94% report sanitation problems, 88% have observed open defecation, and 71% report damaged or full latrines. However, water access is moderate — 51% have enough for drinking, and the median is 12.2 L/p/d. This pattern suggests that water infrastructure exists but sanitation infrastructure has failed. The group's top WASH concern is sanitation (39%). It is concentrated in Camp B (54%, managed by SCI).

**Cluster 2 — "Multi-Sector Crisis" (145 households, 39.3%)**

The largest deprived group, characterised by compounding deprivation across water, sanitation, and hygiene simultaneously. 80% report water access problems, 80% need more than 31 minutes to fetch water, and the median water consumption is just 10.7 litres per person per day — well below the Sphere minimum. Sanitation problems affect 61%, and soap availability is only 3%. This group also has the highest disability prevalence at 50%. It is concentrated in Camp C (36%, managed by TGH) and Camp B (35%).

### 8.4 Geographic Distribution (K=3)

A Chi-square test confirmed an even stronger geographic association for K=3 than for K=2: **Chi-square = 164.5, p = 6.5×10⁻³³** (df = 6).

| Camp | Organisation | Low Need (C0) | Sanitation Crisis (C1) | Multi-Sector Crisis (C2) |
|---|---|---|---|---|
| Camp A | IRC | 55% | 9% | 36% |
| Camp B | SCI | 8% | 51% | 41% |
| Camp C | TGH | 5% | 2% | 93% |
| Camp D | SI | 73% | 14% | 13% |

Camp C is almost entirely within the Multi-Sector Crisis cluster (93%), making it the clearest priority for integrated water, sanitation, and hygiene interventions. Camp B is split between the Sanitation Crisis and Multi-Sector Crisis clusters, suggesting that while sanitation is the dominant issue, a substantial minority also face water access problems. Camp D and Camp A have the highest proportions of Low Need households.

### 8.5 Humanitarian Implications of K=3

The three-cluster view offers more actionable targeting than K=2:

- **Camp C (TGH area):** Requires a comprehensive, multi-sector WASH response — water trucking or new water points to address acute water scarcity, latrine rehabilitation, and hygiene kit distribution. The 80% with fetch times over 31 minutes suggests water infrastructure is physically distant or insufficient.
- **Camp B (SCI area):** The primary investment should be in sanitation infrastructure — constructing new latrines, repairing damaged ones, and addressing open defecation. Water supply, while below ideal, is not as critical as in Camp C.
- **Camps A and D:** While containing the majority of Low Need households, both camps still have minorities in deprived clusters. Monitoring and maintenance of existing infrastructure, rather than emergency-scale intervention, is the appropriate response.

### 8.6 K=2 vs K=3 — Complementary Views

The two analyses are complementary rather than competing. K=2 provides the clearest overall picture: the camp has two fundamentally different levels of WASH access, driven primarily by water access problems, latrine damage, and sanitation conditions. K=3 refines this by distinguishing two types of deprivation within the high-vulnerability population — one dominated by sanitation failure (Camp B) and one by multi-sector collapse (Camp C). For strategic planning, K=2 identifies where the need is; for operational programming, K=3 identifies what type of response is needed.

---

## 9. Summary of Analytical Pipeline

```
Raw survey data (369 HH × 234 variables)
        │
        ▼
Feature selection → 70 meaningful WASH indicators
        │
        ▼
Encoding & cleaning → all numeric, no missing values
        │
        ▼
Feature engineering → L/p/d, vulnerability score, coping counts
        │
        ▼
Standardisation → z-score (mean=0, sd=1)
        │                     [369 HH × 70 features]
        ▼
PCA transformation → dimensionality reduction
        │                     [369 HH × 20 components] ← LATENT SPACE
        ▼
K selection → elbow, silhouette (K=2 optimal), Calinski-Harabasz
        │
        ▼
K-Means clustering ON PCA COMPONENTS → 2 clusters assigned
        │                     [Clustering happens in 20D PCA space]
        ▼
Validation → hierarchical clustering confirms (86% agreement)
        │
        ▼
MAP BACK TO ORIGINAL FEATURES → cluster means in feature space
        │                     [Profiles expressed in 70 WASH indicators]
        ▼
Profiling → Kruskal-Wallis significance tests
        │
        ▼
Geographic analysis → Chi-square camp association (p=2.3×10⁻²⁴)
        │
        ▼
K=3 refinement → subdivides high-vulnerability group (silhouette=0.554)
        │
        ▼
Actionable insights → camp-specific humanitarian recommendations
```

**Key insight:** Clustering discovers patterns in the **abstract PCA space** (where households are represented by their PC1-PC20 scores), then maps the resulting cluster assignments back to **interpretable WASH indicators** (the original 70 features) for profiling and reporting. This two-stage approach ensures both statistical rigor and programmatic relevance.

---

## 10. Limitations and Caveats

**PCA on mixed-type data.** While PCA is a standard dimensionality reduction technique, it assumes continuous, linearly-related variables. This dataset is 77% binary/ordinal and only 8% truly continuous. The sensitivity analysis (Section 9, Stage 10) compared PCA against FAMD (Factor Analysis of Mixed Data), which is theoretically more appropriate for mixed categorical-continuous data. The 91% agreement between PCA-based and FAMD-based cluster assignments suggests PCA is sufficiently robust for this analysis, but **future work should consider using FAMD as the primary dimensionality reduction method** rather than a validation check. FAMD handles categorical variables using chi-square distances (not covariance) and automatically balances feature weights to prevent one-hot encoded variables from being over-represented. The Python pipeline already includes FAMD implementation in the sensitivity analysis section, making this methodological refinement straightforward to implement.

**PCA interpretability trade-off.** While clustering on principal components produces more robust results than clustering on raw features (by reducing noise and removing correlations), it comes at a cost: we cannot directly say "Cluster 0 is defined by households with PC1 < -0.5" because PC1 itself is a weighted mixture of all 67-69 features. This is why the profiling step (mapping back to original features) is essential — it translates the abstract PCA-space clusters into concrete WASH indicators like "79% with water access problems" or "10.5 L/p/d median." The alternative (clustering directly on standardized features) would be more interpretable but statistically weaker due to the curse of dimensionality.

**Cluster count.** The primary analysis identified two clusters as the dominant axis of variation, while the K=3 refinement revealed two distinct sub-types of deprivation within the high-vulnerability group. Further subdivision (K=4 or higher) could reveal additional nuance, though the diminishing silhouette scores suggest that the strongest structure has already been captured.

**Self-reported data.** Survey responses reflect perceptions, which may differ from objective conditions. Social desirability bias or survey fatigue could affect responses.

**Organisation effects.** The geographic concentration of clusters could partly reflect differences in how the four organisations administered the survey. However, the consistency across many independent indicators (water, sanitation, hygiene, demographics) makes this unlikely to be the sole explanation.

**Cross-sectional snapshot.** The survey captures a single point in time. Conditions may have changed since data collection.

**PCA variance spread.** With the first 10 components explaining only 41.6% of variance (and 20 components capturing ~65%), the data is genuinely high-dimensional. The clustering captures the strongest signal, but subtler patterns in the remaining variance may hold additional insights.

---

*Analysis performed February 2026. Tools: Python (pandas, scikit-learn, scipy), K-Means and Ward hierarchical clustering, PCA, Kruskal-Wallis tests, Chi-square test of independence.*
