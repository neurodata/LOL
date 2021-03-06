## Projection Analysis

#----------------------
## Load Packages
#----------------------
require(oro.nifti)
require(ramify)
require(parallel)
require(profmem)
require(FlashR)
require(MASS)
require(dplyr)
require(plyr)
require(randomForest)
source('flashLol.R')

#----------------------
## Prepare Data
#----------------------
dataset <- "SWU4"
n.folds <- 10
mc.cores <- detectCores()
fnames <- list.files('/brains/dwi')
fnames <- fnames[fnames != "lost+found"]

# strip the subject ids from the file names
subids <- sapply(strsplit(fnames, "-|_"), function(r) r[2])
if (dataset == "Templeton114" | dataset == "Templeton255" | dataset == "MRN114") {
  subids <- as.character(subids)
} else {
  subids <- as.numeric(subids)
}

# read the phenotypic data
pheno.dat <- read.csv(sprintf('/brains/%s.csv', dataset))
if (dataset == "Templeton114" | dataset == "MRN114") {
  pheno.dat <- pheno.dat %>%
    rename(c("URSI"="SUBID", "Sex"="SEX"))
} else if (dataset == "KKI2009") {
  pheno.dat <- pheno.dat %>%
    rename(c("SubjectID"="SUBID", "Sex"="SEX")) %>%
    mutate(SEX=recode_factor(SEX, `F`=0, `M`=1))
} else if (dataset == "Templeton255") {
  pheno.dat <- pheno.dat %>%
    rename(c("ursi"="SUBID", ""))
}
# remove duplicate rows which contain invalid entries
pheno.dat <- pheno.dat %>%
  filter(!duplicated(pheno.dat$SUBID)) %>%
  select(SUBID, SEX)

# compute the subject ids that have a phenotypic label in case
# there are subjects lacking phenotypic information
matched.idx <- sapply(subids, function(x) {
  match <- which(x == pheno.dat$SUBID)
  if (length(match) > 0) {
    return(match)
  } else {
    return(NULL)
  }
})
# compute entries that do not have a match
retain.idx <- which(sapply(matched.idx, is.null))
# remove them if necessary
if (length(retain.idx) > 0) {
  print("Removing Subjects without a match...")
  print(retain.idx)
  matched.idx <- matched.idx[-retain.idx]
  fnames <- fnames[-retain.idx]
}
# response of interest is sex
Y <- pheno.dat$SEX[as.numeric(unlist(matched.idx))]

mask <- readNIfTI("/data/MNI152_T1_1mm_brain_mask.nii.gz")
ndim <- prod(dim(mask))
tic <- Sys.time()
# load the data item-by-item and mask off the non-brain portions
res <- mclapply(1:length(fnames), function(i) {
  print(i)
  img <- readNIfTI(paste("/brains/dwi/", fnames[i], sep=""))
  # mask each direction
  X <- apply(img, MARGIN=c(4), function(x) {x[mask > 0]})
  gc()
  # smash!
  return(c(X))
}, mc.cores=3*mc.cores/4)
toc <- Sys.time()
runtime.mtx <- toc - tic
gc()
D <- fm.as.matrix(do.call(rbind, res))  # bind it all
rm(res)  # spare the RAM

# projection strategies of interest
proj.algs <- list(PCA=flashx.pca, LOL=flashx.lol, LDA=flashx.lrlda, RP=flashx.rp)
# store the classifiers of interest
classifier.algs <- list(LDA=lda, RF=randomForest)
# compute which ids will be part of which folds
k.folds <- split(1:length(Y), rep(1:n.folds), drop=TRUE)  # split the sample ids into xval folds

#----------------------
## Algorithm Execution
#----------------------
xv.res <- lapply(1:n.folds, function(j) {
  # obtain training and testing folds
  test.idx <- k.folds[[j]]; train.idx <- (1:length(Y))[!(1:length(Y) %in% k.folds[[j]])]
  D.train <- fm.get.rows(D, train.idx); D.test <- fm.get.rows(D, test.idx)
  Y.train <- as.integer(Y[train.idx]); Y.test <- as.integer(Y[test.idx])
  # loop over projection strategies
  xv.res.fold <- lapply(names(proj.algs), function(proj.name) {
    proj.alg <- proj.algs[[proj.name]]

    # project using strategy proj.name
    proj.res <- do.call(proj.alg, list(X=D.train, Y=Y.train, r=min(length(Y.train), 100)))
    # store the training and testing projections
    op <- (list(X.train=as.matrix(proj.res$Xr), X.test=flashx.embed(D.test, proj.res$A)))
    lapply(seq(1, min(length(Y.train), 100), 10), function(r) {
      # grab the top r columns
      X.train <- op$X.train[,1:r, drop=FALSE]; X.test <- op$X.test[,1:r, drop=FALSE]
      lapply(names(classifier.algs), function(class.name) {
        tryCatch({
          class.alg <- classifier.algs[[class.name]]
          # train classifier of interest
          trained.classifier <- do.call(class.alg, list(X.train, as.factor(Y.train)))
          Y.hat <- predict(trained.classifier, X.test)  # make predictions
          if (class.name == "LDA") {
            Y.hat <- Y.hat$class  # MASS::lda puts the class labels in this attribute
          }
          # compute accuracy
          acc <- mean(Y.hat == Y.test)
          # return as a data frame
          return(data.frame(Dataset=dataset, Algorithm=proj.name, Classifier=class.name,
                            Accuracy=acc, Misclassification=1-acc, r=r, Fold=j))},
          error=function(e) {print(e); return(NULL)})
      }) %>%
        bind_rows()
    }) %>%
      bind_rows()
  }) %>%
    bind_rows()
  rm(D.train, D.test)
  gc()
  saveRDS(list(xv=xv.res.fold), sprintf('/brains/Dataset-%s_flashlol_fold-%s.rds', dataset, j))
  return(xv.res.fold)
}) %>%
  bind_rows()

saveRDS(list(result=xv.res, k.folds=k.folds, Y=Y), sprintf('/brains/Dataset-%s_flashlol.rds', dataset))
