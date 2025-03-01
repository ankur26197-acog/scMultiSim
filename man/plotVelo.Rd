% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/summary_functions.R
\name{plotVelo}
\alias{plotVelo}
\title{Visualize the simulated velocity, colored using the simulated time}
\usage{
plotVelo(
  counts_s,
  velocity,
  cell_time,
  cell_pop,
  width = 20 * 2/3,
  height = 10,
  units = "in",
  dpi = 1000,
  perplexity = 70,
  arrow.length = 1,
  saving = F,
  randseed = 0
)
}
\arguments{
\item{counts_s}{spliced rna counts}

\item{velocity}{true rna velocity}

\item{cell_time}{cell pseudotime}

\item{cell_pop}{cell population metadata}

\item{width}{width of the figure}

\item{height}{height of the figure}

\item{units}{select from "cm", "mm" and "in", default "in"}

\item{dpi}{dpi value of the figure}

\item{perplexity}{perplexity used in tsne visualization}

\item{arrow.length}{number of time units into the future to calculate future cells based on velocity}

\item{saving}{if the plot should be saved into a file}

\item{randseed}{should produce same result if all other parameters are all the same}
}
\value{
None
}
\description{
Visualize the simulated velocity, colored using the simulated time
}
