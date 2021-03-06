
############################################################
############################################################

#####                     CODIGO                       #####

############################################################
############################################################

#####
##### LIBRERIAS
#####

# library(RMariaDB)
# library(DBI)
library(tidyverse)
library(fpp2)
library(TSclust)
library(zoo)
library(tsfknn)
library(factoextra)
library(GMD)

source('~/Dropbox/Tesina/TFM R/cod/ARNN.R')

#####
##### OBTENCION DE TODAS LAS SERIES
#####

################ Sections

# con <- dbConnect(RMariaDB::MariaDB(),
#                  dbname = "tfm",
#                  host = "127.0.0.1",
#                  username = 'root',
#                  password = '',
#                  port = 3306)
# 
# dbListTables(con)
# 
# res <- dbSendQuery(con, paste("SELECT * FROM ",dbListTables(con)[1]))
# data <- dbFetch(res)
# 
# secciones <- data %>%
#   mutate(identificador = paste("eventId", eventId, "-", "sectionId", sectionId)) %>%
#   select(time, identificador, averagePrice) %>%
#   spread(key=identificador, value=averagePrice, fill=NA) %>%
#   select(-time)


################ Zones

# con <- dbConnect(RMariaDB::MariaDB(),
#                  dbname = "tfm",
#                  host = "127.0.0.1",
#                  username = 'root',
#                  password = '',
#                  port = 3306)
# 
# 
# res2 <- dbSendQuery(con, paste("SELECT * FROM ", dbListTables(con)[2]))
# data2 <- dbFetch(res2)
# 
# zonas <- data2 %>%
#   mutate(identificador = paste("eventId", eventId, "-", "zoneId", zoneId)) %>%
#   select(time, identificador, averagePrice) %>%
#   spread(key = identificador, value = averagePrice, fill = NA) %>%
#   select(-time)
# 
# series <- bind_cols(secciones, zonas)
# 
# dbDisconnect(con)

# write.csv(series, "~/Desktop/data.csv", row.names = FALSE)

series <- read.csv("~/Desktop/data.csv")

## relleno NAs (no hago interpolación)

series <- na.locf(series, fromLast = TRUE, na.rm = F) #a los NA les pongo el siguiente valor conocido
series <- na.locf(series, na.rm = F) #a los NA restantes tras el paso anterior, les pongo el anterior valor conocido


## quitar las series que sean constantes

desviacion <- apply(series, MARGIN = 2, FUN = sd)
cond <- desviacion != 0

cond2 <- which(cond == T)

series_planas <- series %>% select(-cond2) #a estas series le voy a aplicar método de prediccion naive
series <- series %>% select(cond2) #me quedo con las series que tienen alguna variacion en el precio, para poder estandarizarlas


rm(con, data, data2, res, res2, secciones, zonas, desviacion, cond, cond2)


# convierto las series a formato ts

series <- ts(series, frequency = 24)
series_planas <- ts(series_planas)





#####
##### CLUSTERING
#####


################ Estandarizacion de las series ((observacion - media) / desviacion)

series_st <- scale(series)


################ Muestra de entrenamiento

series_entr <- ts(series_st[1:(nrow(series_st)-24),], frequency = 24)
series_test <- ts(series_st[(nrow(series_st)-23):nrow(series_st),], frequency = 24)


################ Medidas 

## Distancia Euclidea

inicio <- Sys.time()
IP.dis <- diss(series_entr, "EUCL")
fin <- Sys.time()
temp_eucl <- fin - inicio


## Distancia Correlacion

inicio <- Sys.time()
IP.dis <- diss(series_entr, "COR")
fin <- Sys.time()
temp_cor <- fin - inicio


## Distancia DTWARP

inicio <- Sys.time()
IP.dis <- diss(series_entr, "DTWARP")
fin <- Sys.time()
temp_dtwarp <- fin - inicio


## Tiempos medidas

tiempo_base <- 1
tm_cor <- as.double(temp_cor) / as.double(temp_eucl)
tm_dtwarp <- as.double(temp_dtwarp * 60) / as.double(temp_eucl)

resumen_tiemp_dist <- rbind(
  tiempo_base,
  tm_cor,
  tm_dtwarp
)

rownames(resumen_tiemp_dist) <- c(
  "Distancia Euclídea",
  "Distancia Correlación",
  "Distancia Dynamic Time Warping"
)

View(resumen_tiemp_dist)


## Seleccion de la medida de correlacion

IP.dis <- diss(series_entr, "COR")

################ Cluster

## Metodo Silhouette

silhouette_score <- function(x){
  ss <- silhouette(cutree(hclust(IP.dis), x), IP.dis)
  mean(ss[, 3])
}

k <- 2:20

avg_sil <- sapply(k, silhouette_score)

ggplot(data.frame(k, avg_sil), aes(x = k, y = avg_sil)) + geom_point(shape = 16, size = 2) + geom_line() +
  labs(x = 'Número de clusters', y = 'Puntajes de Average Silhouette') +
  scale_x_continuous(labels = as.character(k), breaks = k)

k <- 2 #maximiza silhoutte

clust_silh <- silhouette(cutree(hclust(IP.dis), k), IP.dis)

fviz_silhouette(clust_silh)


## Metodo Elbow

hclust.obj <- hclust(IP.dis)

css.obj <- css.hclust(IP.dis, hclust.obj)
elbow.obj <- elbow.batch(css.obj)

k <- elbow.obj$k # k = 11

ggplot(css.obj, aes(x = k, y = ev)) + geom_point(shape = 16, size = 2) + geom_line() +
  labs(x = 'Número de clusters', y = 'Varianza intra-cluster') +
  scale_x_continuous(labels = as.character(css.obj$k), breaks = css.obj$k)

## Seleccion de k = 11

k <- 11

IP.hclus <- cutree(hclust(IP.dis), k)

series_entr_cl <- vector("list", k)
series_test_cl <- vector("list", k)

for (i in 1:k) {
  series_entr_cl[[i]] <- series_entr[,IP.hclus == i]
  series_test_cl[[i]] <- series_test[,IP.hclus == i]
}



###### prediccion Naive para todos los clusters

start_time <- Sys.time()

matriz_mse_naive <- matrix(ncol = k, nrow = 1)
matriz_mae_naive <- matrix(ncol = k, nrow = 1)

for (j in 1:k) {

  mse_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  mae_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  
  if(ncol(as.data.frame(series_entr_cl[[j]])) != 1){

    for (i in 1:ncol(series_entr_cl[[j]])) {
      
      pred <- naive(series_entr_cl[[j]][, i], 24)
      error <- (as.vector(pred$mean) - as.vector(series_test_cl[[j]][, i]))
      mse_cluster[1,i] <- mean(error^2, na.rm=TRUE)
      mae_cluster[1,i] <- mean(abs(error), na.rm=TRUE)
      
    }
    
  } else{
    
    pred <- naive(series_entr_cl[[j]], 24)
    error <- (as.vector(pred$mean) - as.vector(series_test_cl[[j]]))
    mse_cluster[1] <- mean(error^2, na.rm=TRUE)
    mae_cluster[1] <- mean(abs(error), na.rm=TRUE)
    
  }
  
  matriz_mse_naive[1,j] <- sum(mse_cluster)
  matriz_mae_naive[1,j] <- sum(mae_cluster)
  
}

end_time <- Sys.time()
time_naive <- end_time - start_time


###### prediccion SES para todos los clusters (tengo que calcular el modelo uno a uno, por lo que tiene un coste computacional muy alto para Producción)

start_time <- Sys.time()

matriz_mse_ses <- matrix(ncol = k, nrow = 1)
matriz_mae_ses <- matrix(ncol = k, nrow = 1)

for (j in 1:k) {
  
  mse_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  mae_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  
  if(ncol(as.data.frame(series_entr_cl[[j]])) != 1){
    
    for (i in 1:ncol(series_entr_cl[[j]])) {
      
      pred <- ses(series_entr_cl[[j]][, i], h=24)
      error <- (as.vector(pred$mean) - as.vector(series_test_cl[[j]][, i]))
      mse_cluster[1,i] <- mean(error^2, na.rm=TRUE)
      mae_cluster[1,i] <- mean(abs(error), na.rm=TRUE)
      
    }
    
  } else{
    
    pred <- ses(series_entr_cl[[j]], h=24)
    error <- (as.vector(pred$mean) - as.vector(series_test_cl[[j]]))
    mse_cluster[1] <- mean(error^2, na.rm=TRUE)
    mae_cluster[1] <- mean(abs(error), na.rm=TRUE)
    
  }
  
  matriz_mse_ses[1,j] <- sum(mse_cluster)
  matriz_mae_ses[1,j] <- sum(mae_cluster)
  
}

end_time <- Sys.time()
time_ses <- end_time - start_time


###### prediccion Holt Damped para todos los clusters 

start_time <- Sys.time()

matriz_mse_holt <- matrix(ncol = k, nrow = 1)
matriz_mae_holt <- matrix(ncol = k, nrow = 1)

for (j in 1:k) {
  
  mse_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  mae_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  
  if(ncol(as.data.frame(series_entr_cl[[j]])) != 1){
    
    for (i in 1:ncol(series_entr_cl[[j]])) {
      
      pred <- holt(series_entr_cl[[j]][, i], damped = TRUE, h=24)
      error <- (as.vector(pred$mean) - as.vector(series_test_cl[[j]][, i]))
      mse_cluster[1,i] <- mean(error^2, na.rm=TRUE)
      mae_cluster[1,i] <- mean(abs(error), na.rm=TRUE)
      
    }
    
  } else{
    
    pred <- holt(series_entr_cl[[j]], damped = TRUE, h=24)
    error <- (as.vector(pred$mean) - as.vector(series_test_cl[[j]]))
    mse_cluster[1] <- mean(error^2, na.rm=TRUE)
    mae_cluster[1] <- mean(abs(error), na.rm=TRUE)
    
  }
  
  matriz_mse_holt[1,j] <- sum(mse_cluster)
  matriz_mae_holt[1,j] <- sum(mae_cluster)
  
}

end_time <- Sys.time()
time_holt <- end_time - start_time


###### prediccion Arima Total para todos los clusters (auto.arima)

start_time <- Sys.time()

matriz_mse_arima <- matrix(ncol = k, nrow = 1)
matriz_mae_arima <- matrix(ncol = k, nrow = 1)

for (j in 1:k) {
  
  mse_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  mae_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  
  if(ncol(as.data.frame(series_entr_cl[[j]])) != 1){
    
    for (i in 1:ncol(series_entr_cl[[j]])) {
      
      pred <- auto.arima(series_entr_cl[[j]][, i]) %>% forecast(h = 24)
      error <- (as.vector(pred$mean) - as.vector(series_test_cl[[j]][, i]))
      mse_cluster[1,i] <- mean(error^2, na.rm=TRUE)
      mae_cluster[1,i] <- mean(abs(error), na.rm=TRUE)
      
    }
    
  } else{
    
    pred <- auto.arima(series_entr_cl[[j]]) %>% forecast(h = 24)
    error <- (as.vector(pred$mean) - as.vector(series_test_cl[[j]]))
    mse_cluster[1] <- mean(error^2, na.rm=TRUE)
    mae_cluster[1] <- mean(abs(error), na.rm=TRUE)
    
  }
  
  matriz_mse_arima[1,j] <- sum(mse_cluster)
  matriz_mae_arima[1,j] <- sum(mae_cluster)
  
}

end_time <- Sys.time()
time_arima <- end_time - start_time


###### prediccion Arima para todos los clusters (SELECCION)

start_time <- Sys.time()

set.seed(1234)

matriz_mse_arima_sl <- matrix(ncol = k, nrow = 1)
matriz_mae_arima_sl <- matrix(ncol = k, nrow = 1)

for (j in 1:2) {
  
  mse_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  mae_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  
  if(ncol(as.data.frame(series_entr_cl[[j]])) != 1){
    
    ind <- sample(1:ncol(series_entr_cl[[j]]), 1)
    
    modelo <- auto.arima(series_entr_cl[[j]][,ind])
    
    for (i in 1:ncol(series_entr_cl[[j]])) {
      
      pred <- Arima(series_entr_cl[[j]][, i], model = modelo) %>% forecast(h = 24)
      error <- (as.vector(pred$mean) - as.vector(series_test_cl[[j]][, i]))
      mse_cluster[1,i] <- mean(error^2, na.rm=TRUE)
      mae_cluster[1,i] <- mean(abs(error), na.rm=TRUE)
      
    }
    
  } else{
    
    pred <- auto.arima(series_entr_cl[[j]]) %>% forecast(h = 24)
    error <- (as.vector(pred$mean) - as.vector(series_test_cl[[j]]))
    mse_cluster[1] <- mean(error^2, na.rm=TRUE)
    mae_cluster[1] <- mean(abs(error), na.rm=TRUE)
    
  }
  
  matriz_mse_arima_sl[1,j] <- sum(mse_cluster)
  matriz_mae_arima_sl[1,j] <- sum(mae_cluster)
  
}

end_time <- Sys.time()
time_arima_sl <- end_time - start_time


###### prediccion Knn para todos los clusters

start_time <- Sys.time()

matriz_mse_knn <- matrix(ncol = k, nrow = 1)
matriz_mae_knn <- matrix(ncol = k, nrow = 1)


for (j in 1:k) {
  
  mse_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  mae_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  
  if(ncol(as.data.frame(series_entr_cl[[j]])) != 1){
    
    for (i in 1:ncol(series_entr_cl[[j]])) {
      
      pred <- knn_forecasting(series_entr_cl[[j]][, i], h = 24, lags = 1:24, k = 25)
      error <- (as.vector(pred$prediction) - as.vector(series_test_cl[[j]][, i]))
      mse_cluster[1,i] <- mean(error^2, na.rm=TRUE)
      mae_cluster[1,i] <- mean(abs(error), na.rm=TRUE)
      
    }
    
  } else{
    
    pred <- knn_forecasting(series_entr_cl[[j]], h = 24, lags = 1:24, k = 25)
    error <- (as.vector(pred$prediction) - as.vector(series_test_cl[[j]]))
    mse_cluster[1] <- mean(error^2, na.rm=TRUE)
    mae_cluster[1] <- mean(abs(error), na.rm=TRUE)
    
  }
  
  matriz_mse_knn[1,j] <- sum(mse_cluster)
  matriz_mae_knn[1,j] <- sum(mae_cluster)
  
}

end_time <- Sys.time()
time_knn <- end_time - start_time


###### prediccion Red Neuronal Autorregresiva para todos los clusters (ARNN)

fun_amplitud <- function(x){
  range(x)[2]-range(x)[1]
}

start_time <- Sys.time()

set.seed(123)

matriz_mse_arnn <- matrix(ncol = k, nrow = 1)
matriz_mae_arnn <- matrix(ncol = k, nrow = 1)

for (j in 1:k) {
  
  mse_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  mae_cluster <- matrix(ncol = ncol(as.data.frame(series_entr_cl[[j]])), nrow = 1)
  
  if(ncol(as.data.frame(series_entr_cl[[j]])) != 1){
    
    max_amplitud <- lapply(series_entr_cl[[j]], fun_amplitud)
    ind <- which.max(max_amplitud)
    
    modelo <- arnn(x = series_entr_cl[[j]][, ind], lags = 1:24, H = 30, isMLP = FALSE, restarts = 3) # lags son los datos de entrada, H las neuronas
    
    for (i in 1:ncol(series_entr_cl[[j]])) {
      
      pred <- arnn(x = series_entr_cl[[j]][, i], model = modelo) %>% forecast(h = 24)
      error <- (as.vector(pred$mean) - as.vector(series_test_cl[[j]][, i]))
      mse_cluster[1,i] <- mean(error^2, na.rm=TRUE)
      mae_cluster[1,i] <- mean(abs(error), na.rm=TRUE)
      
    }
    
  } else{
    
    pred <- arnn(x = series_entr_cl[[j]], lags = 1:24, H = 30, isMLP = FALSE, restarts = 3) %>% forecast(h = 24)
    error <- (as.vector(pred$mean) - as.vector(series_test_cl[[j]]))
    mse_cluster[1] <- mean(error^2, na.rm=TRUE)
    mae_cluster[1] <- mean(abs(error), na.rm=TRUE)
    
  }
  
  matriz_mse_arnn[1,j] <- sum(mse_cluster)
  matriz_mae_arnn[1,j] <- sum(mae_cluster)
  
}

end_time <- Sys.time()
time_arnn <- end_time - start_time



#####
##### SELECCION MODELO POR CLUSTER
#####


########## MSE

resumen_mse <- bind_rows(
  as.data.frame(matriz_mse_naive), 
  as.data.frame(matriz_mse_ses),
  as.data.frame(matriz_mse_holt),
  as.data.frame(matriz_mse_arima),
  as.data.frame(matriz_mse_arima_sl),
  as.data.frame(matriz_mse_knn),
  as.data.frame(matriz_mse_arnn)
)

colnames(resumen_mse) <- c(
  "Cluster 1",
  "Cluster 2",
  "Cluster 3",
  "Cluster 4",
  "Cluster 5",
  "Cluster 6",
  "Cluster 7",
  "Cluster 8",
  "Cluster 9",
  "Cluster 10",
  "Cluster 11"
)

rownames(resumen_mse) <- c(
  "Metodo Naive",
  "Metodo Alisado Exponencial Simple",
  "Metodo Holt Damped",
  "Metodo Arima",
  "Metodo Arima con Selección",
  "Metodo KNN",
  "Metodo ARNN"
)

View(resumen_mse)


### Error Promedio MSE por Modelo

error_naive_mse <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mse_naive)) / sum(table(IP.hclus))
error_ses_mse <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mse_ses)) / sum(table(IP.hclus))
error_holt_mse <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mse_holt)) / sum(table(IP.hclus))
error_arima_mse <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mse_arima)) / sum(table(IP.hclus))
error_arima_sl_mse <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mse_arima_sl)) / sum(table(IP.hclus))
error_knn_mse <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mse_knn)) / sum(table(IP.hclus))
error_arnn_mse <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mse_arnn)) / sum(table(IP.hclus))


resumen_error_modelo_mse <- rbind(
  error_naive_mse ,
  error_ses_mse,
  error_holt_mse,
  error_arima_mse,
  error_arima_sl_mse,
  error_knn_mse,
  error_arnn_mse
)

rownames(resumen_error_modelo_mse) <- c(
  "Metodo Naive",
  "Metodo Alisado Exponencial Simple",
  "Metodo Holt Damped",
  "Metodo Arima",
  "Metodo Arima con Selección",
  "Metodo KNN",
  "Metodo ARNN"
)

View(resumen_error_modelo_mse)


########## MAE

resumen_mae <- bind_rows(
  as.data.frame(matriz_mae_naive), 
  as.data.frame(matriz_mae_ses),
  as.data.frame(matriz_mae_holt),
  as.data.frame(matriz_mae_arima),
  as.data.frame(matriz_mae_arima_sl),
  as.data.frame(matriz_mae_knn),
  as.data.frame(matriz_mae_arnn))

colnames(resumen_mae) <- c(
  "Cluster 1",
  "Cluster 2",
  "Cluster 3",
  "Cluster 4",
  "Cluster 5",
  "Cluster 6",
  "Cluster 7",
  "Cluster 8",
  "Cluster 9",
  "Cluster 10",
  "Cluster 11"
)

rownames(resumen_mae) <- c(
  "Metodo Naive",
  "Metodo Alisado Exponencial Simple",
  "Metodo Holt Damped",
  "Metodo Arima",
  "Metodo Arima con Selección",
  "Metodo KNN",
  "Metodo ARNN"
)

View(resumen_mae)


### Error Promedio MAE por Modelo

error_naive_mae <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mae_naive)) / sum(table(IP.hclus))
error_ses_mae <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mae_ses)) / sum(table(IP.hclus))
error_holt_mae <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mae_holt)) / sum(table(IP.hclus))
error_arima_mae <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mae_arima)) / sum(table(IP.hclus))
error_arima_sl_mae <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mae_arima_sl)) / sum(table(IP.hclus))
error_knn_mae <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mae_knn)) / sum(table(IP.hclus))
error_arnn_mae <- sum(as.vector(table(IP.hclus)) * as.vector(matriz_mae_arnn)) / sum(table(IP.hclus))


resumen_error_modelo_mae <- rbind(
  error_naive_mae ,
  error_ses_mae,
  error_holt_mae,
  error_arima_mae,
  error_arima_sl_mae,
  error_knn_mae,
  error_arnn_mae
)

rownames(resumen_error_modelo_mae) <- c(
  "Metodo Naive",
  "Metodo Alisado Exponencial Simple",
  "Metodo Holt Damped",
  "Metodo Arima",
  "Metodo Arima con Selección",
  "Metodo KNN",
  "Metodo ARNN"
)

View(resumen_error_modelo_mae)

########## Tiempos

tiempo_base <- 1
tm_ses <- as.double(time_ses) / as.double(time_naive)
tm_holt <- as.double(time_holt) / as.double(time_naive)
tm_arima <- as.double(time_arima * 60) / as.double(time_naive) #se multiplica por 60 para convertir los minutos en segundos
tm_arima_sl <- as.double(time_arima_sl * 60) / as.double(time_naive) #se multiplica por 60 para convertir los minutos en segundos
tm_knn <- as.double(time_knn) / as.double(time_naive)
tm_arnn <- as.double(time_arnn * 60) / as.double(time_naive)


resumen_tiempos <- rbind(
  tiempo_base ,
  tm_ses,
  tm_holt,
  tm_arima,
  tm_arima_sl,
  tm_knn,
  tm_arnn
)

rownames(resumen_tiempos) <- c(
  "Metodo Naive",
  "Metodo Alisado Exponencial Simple",
  "Metodo Holt Damped",
  "Metodo Arima",
  "Metodo Arima con Seleccion",
  "Metodo KNN",
  "Metodo ARNN"
)

View(resumen_tiempos)

