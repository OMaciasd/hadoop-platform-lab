# hadoop-env.sh — hadoop-platform-lab
# Límites de heap acordes a los límites de memoria del contenedor (compose.yaml).
# Un heap sin controlar en un contenedor de 1 GB provoca OOM-kill del daemon.

export HADOOP_HEAPSIZE_MAX=512
export HDFS_NAMENODE_OPTS="-Xmx512m -XX:+UseG1GC"
export HDFS_DATANODE_OPTS="-Xmx384m -XX:+UseG1GC"
export YARN_RESOURCEMANAGER_OPTS="-Xmx512m -XX:+UseG1GC"
export YARN_NODEMANAGER_OPTS="-Xmx512m -XX:+UseG1GC"

# Log directory (también exportado desde compose.yaml; se fija como system
# property para que log4j resuelva ${hadoop.log.dir}).
export HADOOP_LOG_DIR="${HADOOP_LOG_DIR:-/hadoop/logs}"
export HADOOP_OPTS="${HADOOP_OPTS:-} -Dhadoop.log.dir=${HADOOP_LOG_DIR}"

# DNS: nombres de servicio estables de la red hadoop_lab
export HADOOP_OPTS="${HADOOP_OPTS:-} -Djava.net.preferIPv4Stack=true"
