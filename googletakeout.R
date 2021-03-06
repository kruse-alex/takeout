#############################################################################################################################################
# PACKAGES
#############################################################################################################################################

# pkg
require(dplyr)
require(rjson)
require(jsonlite)
require(bipartite)
require(stringr)
library(qdapTools)
library(tidyr)
require(qdap)
require(igraph)
require(pluralize)
require(tm)
require(ggnetwork)
require(tnet)
library(readr)
require(gganimate)

#############################################################################################################################################
# DATA IMPORT
#############################################################################################################################################

# load file names with json ending
filenames = list.files("C:/Users/akruse/Documents/Projekte_Weitere/Google/Takeout/Takeout/Searches/", pattern="*.json", full.names=TRUE)

# loop: import json files
big_data_list = list()
for(j in 1:length(filenames)){
  
  mydata = rjson::fromJSON(file = filenames[j])
  
  # format json to data frame
  datalist = list()
  for (i in 1:length(mydata$event)) {
    
    dat = as.data.frame(flatten(as.data.frame(mydata$event[[i]])))
    dat = select(dat, contains("timestamp_usec")[1], query.query_text)
    colnames(dat) = c("timestamp","query")
    datalist[[i]] = dat
    
  }
  
  # cobine data from one json to data frame
  big_data = do.call(rbind, datalist)
  big_data_list[[j]] = big_data
  
}

# bind all data frames together
mydata_all = do.call(rbind, big_data_list)
rm(i,j,mydata,datalist,big_data_list,dat, big_data, filenames)

#############################################################################################################################################
# DATA PROCESSING
#############################################################################################################################################

# format googles stupid timestamp to real life
mydata_all$timestamp_real = substr(mydata_all$timestamp, start = 1, stop = 10)
mydata_all$timestamp_real = as.POSIXct(as.numeric(mydata_all$timestamp_real), origin="1970-01-01")

mydata = mydata_all

# regrex
mydata$query = gsub("\\+"," ",mydata$query)

# regrex to remove non R related queries
mydata = mydata[grepl("^r ", mydata$query) | grepl(" r ", mydata$query), ]
mydata$query = gsub("^r ", "", mydata$query)
mydata$query = gsub(" r ", "", mydata$query)
mydata$query = gsub("[[:punct:]]", "", mydata$query)

# remove rare words in queries
mydata_words = mydata$query %>%
  str_split(" ") %>%
  unlist %>%
  table %>%
  data.frame %>%
  arrange(-Freq) %>%
  filter(Freq < 20)
mydata_words = mydata_words$.

mydata$query = removeWords(mydata$query,mydata_words)
mydata = mydata[!(is.na(mydata$query) | mydata$query=="" | mydata$query==" " | mydata$query=="  " | mydata$query=="   " | mydata$query=="    " | mydata$query=="     "), ]

# singularize words
mydata$query = singularize(mydata$query)
mydata$query = gsub("datum","data",mydata$query)

# convert timestamp to year/month
mydata$timestamp = as.numeric(as.character(mydata$timestamp))
mydata = mydata[with(mydata, order(timestamp, decreasing = F)), ]
mydata$timestamp = format(mydata$timestamp_real, "%m-%Y")
checker = as.data.frame(unique(mydata$timestamp))
checker$id = 1:nrow(checker)

mydata = merge(mydata, checker, by.x = "timestamp", by.y = "unique(mydata$timestamp)", all = T)
mydata_all2 = select(mydata, query, id)
colnames(mydata_all2) = c("query","time")
colnames(checker) = c("timestamp","id")
rm(mydata_words)

#############################################################################################################################################
# PREPARE DATA FOR NETWORK OBJECT
#############################################################################################################################################

# loop: create one network for every time period
datalist = list()
datalist1 = list()
for(i in 5:max(mydata_all2$time)){
  
  # filter on time
  mydata = filter(mydata_all2, time <= i)
  
  # compute network edges
  mydata = select(mydata, query)
  mydata$sequence_id = seq(1:nrow(mydata))
  
  x = t(mtabulate(with(mydata, by(query, sequence_id, bag_o_words))) > 0)
  out = x %*% t(x)
  out[upper.tri(out, diag=TRUE)] = NA
  
  links = matrix2df(out, "word1") %>%
    gather(word2, freq, -word1) %>%
    na.omit() 
  
  # remove rare word combinations
  rownames(links) = NULL
  links = filter(links, freq >= 5)
  links$time = i
  
  # compute network nodes
  nodes2 = as.data.frame(unique(links$word2))
  colnames(nodes2) = "names"
  nodes1 = as.data.frame(unique(links$word1))
  colnames(nodes1) = "names"
  nodes = rbind(nodes1,nodes2)
  nodes = as.data.frame(nodes[!duplicated(nodes), ])
  colnames(nodes) = "names"
  rm(nodes1,nodes2)
  rm(out,x)
  
  # add frequency to nodes
  mydata_words = mydata$query %>%
    str_split(" ") %>%
    unlist %>%
    table %>%
    data.frame %>%
    arrange(-Freq) %>%
    filter(Freq > 1)
  
  nodes = merge(nodes, mydata_words, by.x = "names", by.y = ".", all.x = T)
  nodes$time = i
  
  datalist[[i]] = nodes
  datalist1[[i]] = links
  
}

# close loop
nodes = do.call(rbind, datalist)
links = do.call(rbind, datalist1)

#############################################################################################################################################
# CREATE NETWORK OBJECT
#############################################################################################################################################

# create graph
links_max = links[links$time == max(links$time), ]
links_max = select(links_max, word1, word2)
nodes_max = nodes[nodes$time == max(nodes$time), ]
nodes_max = select(nodes_max, names)
net = graph_from_data_frame(d = links_max, vertices = nodes_max, directed=F)
#net = simplify(net, remove.multiple = T, remove.loops = T)

# create network with ggnetwork
n = ggnetwork(net, arrow.gap=0, layout = "fruchtermanreingold", cell.jitter = 0.05, niter = 20000)

# split network in nodes and edges
n_nodes = n[is.na(n$na.y), ]
n_links = n[!is.na(n$na.y), ]

# combine time/freq with nodes
nodes = merge(nodes, n_nodes, by.x = "names", by.y = "vertex.names")

# combine time/Freq with edges
test = select(n_nodes, vertex.names, x)
n_links = merge(n_links, test, by.x = "xend", by.y = "x")
n_links = merge(links, n_links, by.x=c("word2", "word1"), by.y=c("vertex.names.x", "vertex.names.y"))
n_links$word1 = NULL
n_links$Freq = NA
nodes$freq = NA

nodes = select(nodes, x, y, names, Freq, xend, yend, freq, na.x, na.y, time)
colnames(nodes) = c("x", "y", "vertex.names", "Freq", "xend", "yend", "freq", "na.x", "na.y", "time")
n_links = select(n_links, x, y, word2, Freq, xend, yend, freq, na.x, na.y, time)
colnames(n_links) = c("x", "y", "vertex.names", "Freq", "xend", "yend", "freq", "na.x", "na.y", "time")

big_data = rbind(n_links, nodes)
big_data = merge(big_data, checker, by.x = "time", by.y = "id", all.x = T)
big_data = big_data[with(big_data, order(na.y, time)), ]
big_data$timestamp = factor(big_data$timestamp, levels = unique(big_data$timestamp))
#############################################################################################################################################
# PLOT NETWORK
#############################################################################################################################################

# make gplot
pp = ggplot(big_data, aes(x = x, y = y, xend = xend, yend = yend, frame = timestamp)) +
  geom_edges(color = "#9E9E9E") +
  geom_nodelabel(aes(label = big_data$vertex.names, fill = Freq), color = "white") +
  theme_blank() +
  scale_fill_gradient2(low="#8CC4FF", mid = "blue", high="#FF00FF") +
  theme(legend.position="bottom") +
  xlim(0,1) + ylim(0,1) +
  labs(title = paste("From","08-2014","until")) +
  theme(plot.title = element_text(hjust = 0.5, color = "white")) +
  theme(plot.background = element_rect(fill = 'black', colour = 'black')) +
  theme(panel.background = element_rect(fill = 'black', colour = 'black'))

# Save it to Gif
animation::ani.options(interval=1.5)
gganimate(pp, "googlesearch.gif", ani.width=1025, ani.height=512, title_frame = T)
#gganimate(pp)

