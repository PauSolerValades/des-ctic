FROM rocker/r-ver:4.6.0

# Install binary R packages from RSPM (pre-configured in rocker/r-ver)
RUN install2.r --error --skipinstalled --ncpus -1 \
    arrow \
    dplyr \
    ggplot2 \
    optparse \
    survminer \
    && rm -rf /tmp/downloaded_packages \
    && strip /usr/local/lib/R/site-library/*/libs/*.so

# survival is bundled with R — no install needed
