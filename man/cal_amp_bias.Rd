% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/simulation_functions.R
\name{cal_amp_bias}
\alias{cal_amp_bias}
\title{Simulate technical biases}
\usage{
cal_amp_bias(lenslope, nbins, gene_len, amp_bias_limit)
}
\arguments{
\item{lenslope}{amount of length bias. This value sould be less than 2*amp_bias_limit[2]/(nbins-1)}

\item{nbins}{number of bins for gene length}

\item{gene_len}{transcript length of each gene}

\item{amp_bias_limit}{range of amplification bias for each gene, a vector of length ngenes}
}
\description{
Simulate technical biases
}
