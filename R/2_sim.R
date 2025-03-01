.match_params_den <- function(X, sim, i) {
  N <- sim$N
  if (is.null(sim$param_sample)) {
    sim$param_sample <- list(numeric(), numeric(), numeric())
  }
  # stopifnot(all(dim(X) == c(N$cell, N$gene)))
  ncol_X <- if (is.vector(X)) length(X) else ncol(X)
  stopifnot(ncol_X == N$gene)

  prev_values <- sim$param_sample[[i]]
  values_X <- as.vector(X)
  values <- c(values_X, prev_values)
  ranks <- rank(values)
  sorted <- sort(SampleDen(nsample = max(ranks), den_fun = N$params_den[[i]]))
  if (length(prev_values) < 20000) {
    sim$param_sample[[i]] <- values
  }
  # return
  matrix(data = sorted[ranks[1:length(values_X)]], ncol = ncol_X)
}


#' Title
#'
#' @param seed
#' @param sim
#' @param spatial_idx If is spatial, the cell index
#'
#' @return
.get_params <- function(seed, sim, sp_cell_i = NULL, sp_path_i = NULL) {
  set.seed(seed)
  is_spatial <- !is.null(sp_cell_i)

  CIF <- if (is_spatial) {
    setNames(
      lapply(1:2, function(i) {
        cif_ <- sim$CIF_spatial$cif[[sp_cell_i]][[i]]
        # cif_$diff is T if it's need to be combined with the shared diff cif
        cif_diff <- if (cif_$diff) {
          sim$CIF_spatial$diff_cif_by_path[[i]][[sp_path_i]]
        } else {
          NULL
        }
        cbind(cif_$nd, cif_diff, cif_$reg)
      }),
      c("kon", "koff")
    )
  } else {
    sim$CIF_all$cif
  }
  GIV <- sim$GIV
  ATAC_data <- if (is_spatial) {
    idx_on_path <- sim$CIF_spatial$layer_idx_by_path[[sp_path_i]]
    sim$atac_data[idx_on_path, ]
  } else {
    sim$atac_data
  }
  Region_to_gene <- sim$region_to_gene
  N <- sim$N
  options <- sim$options

  params <- setNames(
    lapply(1:2, \(i) .match_params_den(CIF[[i]] %*% t(GIV[[i]]), sim, i)),
    c("kon", "koff")
  )

  # ==== kon: controlled by atac data

  # normalize columns of region_to_gene
  s <- colSums(Region_to_gene)
  cols <- s > 1
  Region_to_gene[, cols] <- Region_to_gene[, cols] / s[cols]
  # atac for kon
  ATAC_kon <- ATAC_data %*% Region_to_gene

  # fill the zero values in ATAC_kon to preserve
  # the orders. Scale the values to less than the minimum value in ATAC_kon.
  # only consider the genes affected by regions
  cols <- s > 0
  atac_holes <- ATAC_kon[, cols] == 0
  stopifnot(length(atac_holes) > 0)
  filler <- params$kon[, cols][atac_holes]
  filler <- filler - min(filler)
  filler <- filler * (min(ATAC_kon[ATAC_kon > 0]) / 2 / max(filler))
  ATAC_kon[, cols][atac_holes] <- filler
  # match density
  atac_eff <- OP(atac.effect)
  atac_val <- ATAC_kon[, cols]
  ranks <- atac_eff * rank(ATAC_kon[, cols]) + (1 - atac_eff) * rank(params$kon[, cols])
  sorted <- sort(SampleDen(nsample = max(ranks), den_fun = N$params_den[[1]]))
  params$kon[, cols] <- sorted[ranks]

  # ==== adjust parameters with the bimod parameter
  bimod_percentage <- 0.5
  bimod_genes <- sample(1:N$gene, ceiling(N$gene * bimod_percentage))
  bimod_vec <- numeric(N$gene)
  bimod_vec[bimod_genes] <- OP(bimod)
  # decrease kon & koff in some genes to increase the bimod effect
  params$kon <- apply(t(params$kon), 2, \(x) 10^(x - bimod_vec))
  params$koff <- apply(t(params$koff), 2, \(x) 10^(x - bimod_vec))

  # return
  params
}


.prepare_hge <- function (seed, sim, s_base) {
  set.seed(seed)
  N <- sim$N
  options <- sim$options
  prop_hge <- OP(hge.prop)
  mean_hge <- OP(hge.mean)
  sd_hge <- OP(hge.sd)
  max_var <- OP(hge.max.var)
  hge_range <- OP(hge.range)
  
  if (prop_hge <= 0){
    sim$hge_scale <- 1
    return()
  }
  
  in_range <- rep(T, N$gene)
  in_range[1:(hge_range - 1)] <- F
  
  gene_var <- colVars(s_base)
  n_hge <- ceiling(N$gene * prop_hge)
  pool <- which(gene_var < max_var & in_range)
  if (length(pool) < n_hge) {
    stop("Too few highly expressed gene candidates. Consider increasing hge.max.var.")
  }
  chosen_hge <- sample(pool, n_hge, replace = F)
  var_rank <- dnorm(gene_var[chosen_hge], 0, max_var / 5)
  d <- dnorm(0, 0, max_var / 5)
  
  multi_factors <- sapply(seq_along(chosen_hge), function(igene){
    if (runif(1, 0, 1) < 1){
      1 + mean_hge * (var_rank[igene] / d) * rnorm_trunc(1, 1, sd_hge, 1, 2)
    } else {
      mean_hge
    }
  })
  
  scales <- rep(1, N$gene)
  scales[chosen_hge] <- multi_factors
  sim$hge_scale <- scales
}


#' Title
#'
#' @param seed
#' @param CIF_atac
#' @param CIF
#' @param RIV
#'
#' @return region x cell matrix
.atac_seq <- function(seed, sim) {
  data(dens_nonzero)
  set.seed(seed)

  options <- sim$options

  # (cell x cif) x (cif x region) => cell x region
  params_region <- sim$CIF_atac %*% t(sim$RIV)
  n_val <- length(params_region)
  # get the rank of all values as an 1d vector (by column)
  ranks <- rank(as.vector(params_region))
  n_zero <- floor(n_val * OP(atac.p_zero))
  n_nonzero <- n_val - n_zero
  # sample values
  sampled <- sort(SampleDen(n_nonzero, den_fun = dens_nonzero))
  # create the result
  res <- numeric(n_val)
  # replace the non-zero indices in the original value with the corresponding
  # sampled values
  # `ranks[ranks > n_zero]` creates a map: orig_idx -> rank
  res[which(ranks > n_zero)] <- 2^(sampled[ranks[ranks > n_zero] - n_zero]) - 1

  sim$atac_data <- matrix(res, nrow = nrow(params_region))
}


.rna_seq <- function(seed, sim) {
  set.seed(seed)

  CIF_all <- sim$CIF_all
  GIV_s <- sim$GIV$s
  GRN <- sim$GRN
  N <- sim$N
  options <- sim$options

  phyla <- OP(tree)
  do_velo <- OP(do.velocity)
  is_discrete <- OP(discrete.cif)

  c(edges, root, tips, internal) %<-% .tree_info(phyla)
  neutral <- CIF_all$neutral[1:N$cell, ]

  # results
  sim$counts_s <- matrix(nrow = N$cell, ncol = N$gene)
  sim$params$s <- matrix(nrow = nrow(sim$params$kon), ncol = ncol(sim$params$kon))

  if (do_velo) {
    sim$root_state <- sample(c(1, 2), size = N$gene, replace = TRUE)

    # results
    sim$counts_u <- matrix(nrow = N$cell, ncol = N$gene)
    sim$state_mat <- matrix(nrow = N$cell, ncol = N$gene)
    sim$cell_time <- numeric(length = N$cell)
    sim$velocity <- matrix(nrow = N$cell, ncol = N$gene)
    sim$d_genes <- rnorm(n = N$gene, mean = OP(d), sd = 0.1)
    sim$beta_genes <- rnorm(n = N$gene, mean = OP(beta), sd = 0.1)
  }
  if (sim$is_dyn_grn) {
    sim$dyngrn_ver_map <- numeric(N$cell)
  }

  no_grn <- is.null(GRN)
  # CIF for regulators; cell x n_regu
  sim$cif_regu <- if (no_grn) {
    NULL
  } else {
    matrix(0, nrow = N$cell, ncol = GRN$n_reg)
  }

  cell_ct <- 1
  s_base <- CIF_all$cif$s %*% t(GIV_s)
  
  oldseed <- .Random.seed
  .prepare_hge(seed, sim, s_base)
  .Random.seed <- oldseed

  if (is_discrete) {
    curr_cif <- if (no_grn) {
      NULL
    } else {
      rnorm(GRN$n_reg, OP(cif.center), OP(cif.sigma))
    }
    .rna_sim_edge(sim, 1:N$cell, s_base, curr_cif, NULL)
    return()
  }

  for (i_edge in 1:nrow(edges)) {
    c(., parent, child, .) %<-% edges[i_edge, ]

    cells_on_edge <- which(neutral[, "from"] == parent & neutral[, "to"] == child)

    is_first_edge <- parent == root
    last_parent <- NULL
    curr_cif <- if (no_grn) {
      NULL
    } else if (is_first_edge) {
      # initial CIF
      rnorm(GRN$n_reg, OP(cif.center), OP(cif.sigma))
    } else {
      # get parent's CIF from last edge
      grandparent <- edges[edges[, "to"] == parent, ]["from"]
      last_parent <- max(which(
        neutral[, "from"] == grandparent & neutral[, "to"] == parent
      ))
      sim$cif_regu[last_parent, ]
    }
    stopifnot(is.null(curr_cif) || any(curr_cif != 0))

    .rna_sim_edge(sim, cells_on_edge, s_base, curr_cif, last_parent)
  }
}


.rna_sim_edge <- function(sim, cell_idx, s_base, curr_cif, last_parent) {
  N <- sim$N
  options <- sim$options
  no_grn <- is.null(curr_cif)

  ncells <- length(cell_idx)
  do_velo <- OP(do.velocity)
  is_discrete <- OP(discrete.cif)
  intr_noise <- OP(intrinsic.noise)
  cycle_length <- OP(cycle.len)
  num_cycle <- OP(num.cycles)

  # each cell
  for (n in seq_along(cell_idx)) {
    i_cell <- cell_idx[n]

    if (sim$is_dyn_grn) {
      sim$dyngrn_ver_map[i_cell] <- sim$GRN$update()
    }

    s_cell <- if (no_grn) {
      .match_params_den(s_base[i_cell, ], sim, 3)
    } else {
      .match_params_den(s_base[i_cell, ] + curr_cif %*% t(sim$GRN$geff), sim, 3)
    }
    s_cell <- (10^s_cell) * OP(scale.s) * sim$hge_scale %>% as.vector()

    counts <- if (do_velo) {
      # Kinetic model
      last_idx <- if (n == 1) last_parent else cell_idx[n - 1]
      FST <- is.null(last_idx)
      cycles <- if (FST) 15 else num_cycle
      start_cell_time <- if (FST) 0 else sim$cell_time[last_idx]

      result <- gen_1branch(
        kinet_params = list(
          k_on = sim$params$kon[, i_cell],
          k_off = sim$params$koff[, i_cell],
          s = s_cell
        ),
        start_state = if (FST) sim$root_state else sim$state_mat[last_idx, ],
        start_u = if (FST) NULL else sim$counts_u[last_idx, ],
        start_s = if (FST) NULL else sim$counts_s[last_idx, ],
        cycle_length_factor = cycle_length,
        randpoints1 = runif(n = cycles, min = 0, max = 1),
        ncells1 = cycles,
        ngenes = N$gene,
        beta_vec = sim$beta_genes,
        d_vec = sim$d_genes,
        cell = n
      )
      sim$state_mat[i_cell, ] <- result$state_mat[, cycles]
      sim$cell_time[i_cell] <- result$cell_time[[cycles]] + start_cell_time
      sim$velocity[i_cell, ] <- result$velocity[, cycles]
      sim$counts_u[i_cell, ] <- result$counts_u[, cycles]
      sim$counts_s[i_cell, ] <- result$counts_s[, cycles]
    } else {
      # Beta-poisson model
      sim$counts_s[i_cell, ] <- sapply(1:N$gene, function(i_gene) {
        K_on <- sim$params$kon[i_gene, i_cell]
        K_off <- sim$params$koff[i_gene, i_cell]
        S <- s_cell[i_gene]
        y_mean <- K_on / (K_on + K_off)
        x_mean <- y_mean * S
        y <- rbeta(1, K_on, K_off)
        x <- rpois(1, y * S)
        # use floor because it's more close to the Poisson distribution
        # floor(intr_noise * x + (1 - intr_noise) * x_mean)
        intr_noise * x + (1 - intr_noise) * x_mean
      })
    }

    if (!is_discrete && !no_grn) {
      counts_regu <- counts[sim$GRN$regulators]
      sim$cif_regu[i_cell, ] <- curr_cif <- counts_regu / (counts_regu + mean(counts))
    }
    sim$params$s[, i_cell] <- s_cell
  }

  stopifnot(n == ncells)
}

.rna_seq.spatial <- function(seed, sim) {
  set.seed(seed)

  grid <- sim$grid
  CIF <- sim$CIF_spatial
  GIV_s <- sim$GIV$s
  GRN <- sim$GRN
  N <- sim$N
  options <- sim$options

  is_debug <- isTRUE(options$debug)
  no_grn <- is.null(GRN)
  phyla <- OP(tree)
  do_velo <- OP(do.velocity)
  intr_noise <- OP(intrinsic.noise)
  has_ctype_factor <- !is.null(sim$sp_ctype_param)
  
  # hge
  CIF_s_base <- lapply(1:N$cell, function (icell) {
    path_i <- sim$cell_path[icell]
    cif_ <- CIF$cif[[icell]]$s
    cif_diff <- if (cif_$diff) {
      CIF$diff_cif_by_path$s[[path_i]]
    } else {
      NULL
    }
    cbind(cif_$nd, cif_diff, cif_$reg)
  })
  s_base <- do.call(rbind, CIF_s_base) %*% t(GIV_s)
  
  oldseed <- .Random.seed
  .prepare_hge(seed, sim, s_base)
  .Random.seed <- oldseed
  # end hge

  c(edges, root, tips, internal) %<-% .tree_info(phyla)

  N_lig_cif <- N$sp_regulators * N$max_nbs
  n_steps <- max(sim$path_len)
  # continue for another 10 steps after the final layer
  n_steps <- n_steps + 10

  # results
  sim$counts_s <- matrix(nrow = N$cell, ncol = N$gene)

  dim_kon <- dim(sim$params_spatial[[1]]$kon)
  sim$params <- list(
    kon = matrix(nrow = dim_kon[1], ncol = dim_kon[2]),
    koff = matrix(nrow = dim_kon[1], ncol = dim_kon[2]),
    d = matrix(nrow = dim_kon[1], ncol = dim_kon[2])
  )
  sim$meta_spatial <- data.frame(
    pop = character(N$cell), depth = numeric(N$cell),
    cell.type = character(N$cell), cell.type.idx = numeric(N$cell)
  )

  if (do_velo) {
    sim$root_state <- sample(c(1, 2), size = N$gene, replace = TRUE)

    # results
    sim$counts_u <- matrix(nrow = N$cell, ncol = N$gene)
    sim$state_mat <- matrix(nrow = N$cell, ncol = N$gene)
    sim$cell_time <- numeric(length = N$cell)
    sim$velocity <- matrix(nrow = N$cell, ncol = N$gene)
    sim$d_genes <- rnorm(n = N$gene, mean = OP(d), sd = 0.1)
    sim$beta_genes <- rnorm(n = N$gene, mean = OP(beta), sd = 0.1)
  }

  # CIF for regulators; cell x n_regu
  sim$cif_regu <- if (no_grn) {
    NULL
  } else {
    matrix(0, nrow = N$cell, ncol = GRN$n_reg)
  }

  curr_cif <- if (no_grn) {
    lapply(1:N$cell, \(.) numeric())
  } else {
    lapply(1:N$cell, \(.) rnorm(GRN$n_reg, OP(cif.center), OP(cif.sigma)))
  }
  curr_lig_cif <- lapply(1:N$cell, \(.)  rnorm(N$sp_regulators, OP(cif.center), OP(cif.sigma)))

  cat("Simulating...")
  for (t_real in 1:n_steps) {
    # num of steps is 10 more than default
    t <- if (t_real > N$cell) N$cell else t_real
    if (t_real %% 50 == 0) cat(sprintf("%d..", t_real))

    # add new cell to the grid
    if (t == t_real) {
      grid$allocate(t, sim$cell_path[t])
    }

    # there are t cells now
    for (icell in 1:t) {
      # the corresponding layer index for this cell
      path_i <- sim$cell_path[icell]
      max_layer <- sim$path_len[path_i]
      layer <- t - icell + 1
      if (layer > max_layer) {
        layer <- max_layer
      }

      # get ligand cif
      neighbours <- grid$get_neighbours(icell)
      lig_cif <- double(N_lig_cif)
      for (i in seq_along(neighbours)) {
        nb <- neighbours[i]
        if (is.na(nb)) next
        # n1_lig1  n1_lig2 | n2_lig1  n2_lig2  ...
        base <- (i - 1) * N$sp_regulators
        inactive_one <- sample(1:N$sp_regulators, 1)
        for (j in 1:N$sp_regulators) {
          ctype_factor <- if (j == inactive_one) {
            0
          } else if (has_ctype_factor) {
            nb_path <- sim$cell_path[nb]
            tp1 <- CIF$meta_by_path[[path_i]][layer, "cell.type.idx"]
            layer2 <- t - nb + 1
            max_layer2 <- sim$path_len[nb_path]
            if (layer2 > max_layer2) layer2 <- max_layer2
            tp2 <- CIF$meta_by_path[[nb_path]][layer2, "cell.type.idx"]
            sim$sp_ctype_param[tp1, tp2, j]
          } else {
            1
          }
          lig_cif[base + j] <- curr_lig_cif[[nb]][j] * ctype_factor
        }
      }
      regu_cif <- c(curr_cif[[icell]], lig_cif)

      # get s cif
      # cif_ <- CIF$cif[[icell]]$s
      # cif_diff <- if (cif_$diff) {
      #   CIF$diff_cif_by_path$s[[path_i]]
      # } else {
      #   NULL
      # }
      # CIF_s <- cbind(cif_$nd, cif_diff, cif_$reg)

      # get s
      params <- sim$params_spatial[[icell]]
      s_cell <- CIF_s_base[[icell]][layer, ] %*% t(GIV_s) +
        regu_cif %*% t(cbind(GRN$geff, sim$sp_effect))
      s_before_sample <- s_cell
      s_cell <- .match_params_den(s_cell, sim, 3)
      s_cell <- (10^s_cell) * OP(scale.s) * sim$hge_scale %>% as.vector()

      # Beta-poisson model
      counts <- sapply(1:N$gene, function(i_gene) {
        K_on <- sim$params_spatial[[icell]]$kon[i_gene, layer]
        K_off <- sim$params_spatial[[icell]]$koff[i_gene, layer]
        S <- s_cell[i_gene]
        y <- rbeta(1, K_on, K_off)
        x <- rpois(1, y * S)
        y_mean <- K_on / (K_on + K_off)
        x_mean <- y_mean * S
        floor(intr_noise * x + (1 - intr_noise) * x_mean)
      })

      counts_regu <- if (no_grn) {
        counts[sim$sp_regulators]
      } else {
        counts[c(sim$GRN$regulators, sim$sp_regulators)]
      }
      next_cif <- counts_regu / (counts_regu + mean(counts))
      # next_cif <- 10 * next_cif

      if (no_grn) {
        curr_lig_cif[[icell]] <- next_cif
      } else {
        curr_cif[[icell]] <- next_cif[1:GRN$n_reg]
        curr_lig_cif[[icell]] <- next_cif[-(1:GRN$n_reg)]
      }
      # if (t == 500) {
      #   if (icell == 1 || !is.null(sim$boc)) browser()
      # }

      if (layer == max_layer || t == N$cell) {
        sim$meta_spatial[icell, ] <- CIF$meta_by_path[[path_i]][layer, ]
        sim$counts_s[icell, ] <- counts
      }
    }
  }

  cat("\n")
}
