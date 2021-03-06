library(msPurity)
library(optparse)
library(xcms)
library(CAMERA)
print(sessionInfo())
print('CREATING DATABASE')


xset_pa_filename_fix <- function(opt, pa, xset){

  if (!is.null(opt$mzML_files) && !is.null(opt$galaxy_names)){
    # NOTE: Relies on the pa@fileList having the names of files given as 'names' of the variables 
    # needs to be done due to Galaxy moving the files around and screwing up any links to files

    filepaths <- trimws(strsplit(opt$mzML_files, ',')[[1]])
    filepaths <- filepaths[filepaths != ""]
    new_names <- basename(filepaths)

    galaxy_names <- trimws(strsplit(opt$galaxy_names, ',')[[1]])
    galaxy_names <- galaxy_names[galaxy_names != ""]

    nsave <- names(pa@fileList)
    old_filenames  <- basename(pa@fileList)
    pa@fileList <- filepaths[match(names(pa@fileList), galaxy_names)]
    names(pa@fileList) <- nsave

    pa@puritydf$filename <- basename(pa@fileList[match(pa@puritydf$filename, old_filenames)])
    pa@grped_df$filename <- basename(pa@fileList[match(pa@grped_df$filename, old_filenames)])
  }


 if(!all(basename(pa@fileList)==basename(xset@filepaths))){
    if(!all(names(pa@fileList)==basename(xset@filepaths))){
       print('FILELISTS DO NOT MATCH')
       message('FILELISTS DO NOT MATCH')
       quit(status = 1)
    }else{
      xset@filepaths <- unname(pa@fileList)
    }
  }

  print(xset@phenoData)
  print(xset@filepaths)

  return(list(pa, xset))
}




option_list <- list(
  make_option(c("-o", "--out_dir"), type="character"),
  make_option("--pa", type="character"),
  make_option("--xset_xa", type="character"),
  make_option("--xcms_camera_option", type="character"),
  make_option("--eic", action="store_true"),
  make_option("--cores", default=4),
  make_option("--mzML_files", type="character"),
  make_option("--galaxy_names", type="character"),
  make_option("--grp_peaklist", type="character"),
  make_option("--db_name", type="character", default='lcmsms_data.sqlite'),
  make_option("--raw_rt_columns", action="store_true"),
  make_option("--metfrag_result", type="character"),
  make_option("--sirius_csifingerid_result", type="character"),
  make_option("--probmetab_result", type="character")
)


# store options
opt<- parse_args(OptionParser(option_list=option_list))
print(opt)

loadRData <- function(rdata_path, name){
  #loads an RData file, and returns the named xset object if it is there
  load(rdata_path)
  return(get(ls()[ls() == name]))
}

print(paste('pa', opt$pa))
print(opt$xset)

print(opt$xcms_camera_option)
# Requires
pa <- loadRData(opt$pa, 'pa')


print(pa@fileList)


if (opt$xcms_camera_option=='xcms'){
  xset <- loadRData(opt$xset, 'xset')
  fix <- xset_pa_filename_fix(opt, pa, xset)  
  pa <- fix[[1]]
  xset <- fix[[2]]
  xa <- NULL
}else{
  
  xa <- loadRData(opt$xset, 'xa')
  fix <- xset_pa_filename_fix(opt, pa, xa@xcmsSet)  
  pa <- fix[[1]]
  xa@xcmsSet <- fix[[2]]
  xset <- NULL
}



if(is.null(opt$grp_peaklist)){
  grp_peaklist = NA
}else{
  grp_peaklist = opt$grp_peaklist
}


db_pth <- msPurity::create_database(pa, xset=xset, xsa=xa, out_dir=opt$out_dir,
                          grp_peaklist=grp_peaklist, db_name=opt$db_name)

if (!is.null(opt$eic)){
  if (is.null(opt$raw_rt_columns)){
    rtrawColumns <- FALSE
  }else{
    rtrawColumns <- TRUE
  }
  if (is.null(xset)){
      xset <- xa@xcmsSet
  }
  # previous check should have matched filelists together
  xset@filepaths <- unname(pa@fileList)

  # Saves the EICS into the previously created database
  px <- msPurity::purityX(xset, saveEIC = TRUE,
                           cores=1, sqlitePth=db_pth,
                           rtrawColumns = rtrawColumns)
}

con <- DBI::dbConnect(RSQLite::SQLite(), db_pth)

add_extra_table_elucidation <- function(name, pth, db_con){
  if (is.null(pth)){
    return(0)
  }
  DBI::dbWriteTable(conn=db_con, name=name, value=pth, sep='\t', header=T)
}

write_to_table <- function(df, db_con, name, append){

  df <- df[!df$UID=='UID',]
  # get peakid, an scan id
  df_ids <- stringr::str_split_fixed(df$UID, '-', 3)
  colnames(df_ids) <- c('grp_id', 'file_id', 'pid')
  df <- cbind(df_ids, df)
  DBI::dbWriteTable(db_con, name=name, value=df, row.names=FALSE, append=append)

}

add_probmetab <- function(pth, xset, con){
  if (!is.null(pth)){

    df <- read.table(pth,  header = TRUE, sep='\t', stringsAsFactors = FALSE,  comment.char = "")
    df$grp_id <- match(df$name, xcms::groupnames(xset))
    start <- T 
    for (i in 1:nrow(df)){

      x <- df[i,]

      if(is.na(x$proba) | x$proba =='NA'){
        next
      }
  
      mpc <- stringr::str_split(x$mpc, ';')
      proba <- stringr::str_split(x$proba, ';') 

      for (j in 1:length(mpc[[1]])){
    
        row <-  c(x$grp_id, x$propmz, mpc[[1]][j], proba[[1]][j])
           
        if (start){
          df_out <- data.frame(t(row), stringsAsFactors=F)
          start <- F
        }else{
          df_out <- data.frame(rbind(df_out, row), stringsAsFactors=F)
        }
      } 
          
     }

     colnames(df_out) <- c('grp_id', 'propmz', 'mpc', 'proba')
     DBI::dbWriteTable(con, name='probmetab_results', value=df_out, row.names=FALSE)

  }
}

add_extra_table_elucidation('metfrag_results', opt$metfrag_result, con)
add_extra_table_elucidation('sirius_csifingerid_results', opt$sirius_csifingerid_result, con)


if (is.null(xset)){
  DBI::dbWriteTable(con, name='xset_classes', value=xa@xcmsSet@phenoData, row.names=TRUE)
  add_probmetab(opt$probmetab_result, xa@xcmsSet,  con)
}else{

  DBI::dbWriteTable(con, name='xset_classes', value=xset@phenoData, row.names=TRUE)
  add_probmetab(opt$probmetab_result, xset,  con)

}

cmd <- paste('SELECT cpg.grpid, cpg.mz, cpg.mzmin, cpg.mzmax, cpg.rt, cpg.rtmin, cpg.rtmax, c_peaks.cid, ',
             'c_peaks.mzmin AS c_peak_mzmin, c_peaks.mzmax AS c_peak_mzmax, ',
             'c_peaks.rtmin AS c_peak_rtmin, c_peaks.rtmax AS c_peak_rtmax, s_peak_meta.*, fileinfo.nm_save as filename',
             'FROM c_peak_groups AS cpg ',
             'LEFT JOIN c_peak_X_c_peak_group AS cXg ON cXg.grpid=cpg.grpid ',
             'LEFT JOIN c_peaks on c_peaks.cid=cXg.cid ',
             'LEFT JOIN c_peak_X_s_peak_meta AS cXs ON cXs.cid=c_peaks.cid ',
             'LEFT JOIN s_peak_meta ON cXs.pid=s_peak_meta.pid ',
             'LEFT JOIN fileinfo ON s_peak_meta.fileid=fileinfo.fileid')

cpeakgroup_msms <- DBI::dbGetQuery(con, cmd)

print(head(cpeakgroup_msms))
write.table(cpeakgroup_msms, file.path(opt$out_dir, 'cpeakgroup_msms.tsv'), row.names=FALSE, sep='\t')
