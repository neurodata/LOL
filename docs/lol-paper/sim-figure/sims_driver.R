# Parallelize Stuff
#=========================#
require(lolR)
require(MASS)
library(parallel)
#classifier.name <- "rf"
#classifier.alg <- randomForest::randomForest
#classifier.return = NaN
classifier.name <- 'lda'
classifier.alg <- MASS::lda
classifier.return <- "class"
simn <- 3

no_cores = detectCores() - 1

n=100
niter <- 100  # number of iterations per simulation
rlen <- 15
# the simulations to call themselves
sims <- list(lol.sims.rtrunk, lol.sims.cross, lol.sims.rev_rtrunk)

sims <- sims[simn]


maxr <- c(30, 30, 30)
maxr <- maxr[simn]
ds <- c(100, 100, 90)
ds <- ds[simn]
# additional arguments for each simulation scenario
opt_args <- list(list(K=3), list(rotate=TRUE), list(robust=0.4))
opt_args <- opt_args[[simn]]
sim_names = c("Trunk-3", "Cross", "Robust")
sim_names <- sim_names[simn]


algs <- list(lol.project.pca, lol.project.lrlda, lol.project.lrcca, lol.project.rp, lol.project.pls,
             lol.project.lol, lol.project.lol, lol.project.lol)
names(algs) <- c("PCA", "LRLDA", "CCA", "RP", "PLS", "LOL", "QOL", "RLOL")
alg.opts=list(list(), list(), list(), list(), list(), list(), list(second.moment="quadratic"), list(robust.first=TRUE, robust.second=TRUE))
names(alg.opts) <- c("PCA", "LRLDA", "CCA", "RP", "PLS", "LOL", "QOL", "RLOL")

simulations <- list()
counter <- 1

for (i in 1:length(sims)) {
  for (j in 1:niter) {
    simulations[[counter]] <- list(sim_func=sims[[i]], args=c(list(n, ds[i]), opt_args[[i]]),
                                   rmax=maxr[i], sim=sim_names[i], iter=j)
    counter <- counter + 1
  }
}

time.before=Sys.time()
# Setup Algorithms
#=========================#
opath <- './data/sims'
results <- mclapply(simulations, function(sim) {

  sim_dat <- do.call(sim$sim_func, sim$args)
  X <- sim_dat$X; Y <- sim_dat$Y
  results <- data.frame(sim=c(), iter=c(), alg=c(), r=c(), lhat=c())

  log.seq <- function(from=0, to=30, length=rlen) {
    round(exp(seq(from=log(from), to=log(to), length.out=length)))
  }

  rs <- unique(round(log.seq(from=1, to=sim$rmax, length=rlen)))
  results <- data.frame(sim=c(), iter=c(), fold=c(), alg=c(), r=c(), lhat=c())
  for (i in 1:length(algs)) {
    classifier.ret <- classifier.return
    if (classifier.name == "lda") {
      classifier.ret = "class"
      classifier.alg = MASS::lda
    }
    if (sim$sim == "Cross") {  # for cross simulation, use QDA
      classifier.alg=MASS::qda
      classifier.ret = "class"
    }
    if (names(algs)[i] == "CCA") {  # CCA produces turrible embeddings that dont work w LDA as they are singular
      classifier.alg = lol.classify.nearestCentroid
      classifier.ret = NaN
    }
    tryCatch({
      xv_res <- lol.xval.optimal_dimselect(X, Y, rs, algs[[names(algs)[i]]], alg.opts=alg.opts[[names(algs)[i]]],
                                           alg.return="A", classifier=classifier.alg,
                                           classifier.return=classifier.ret, k='loo')
      results <- rbind(results, data.frame(sim=sim$sim, iter=sim$iter, fold=xv_res$folds.data$fold, alg=names(algs)[i],
                                           r=xv_res$folds.data$r, lhat=xv_res$folds.data$lhat))
    }, error=function(e) lhat <- NaN)
  }
  return(results)
}, mc.cores=no_cores)
time.after=Sys.time()

# Aggregate and save
#=================================#
resultso <- do.call(rbind, results)
saveRDS(resultso, file.path(opath, paste('lol_sims_', classifier.name, "_", simn, '.rds', sep="")))
