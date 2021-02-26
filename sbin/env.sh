if [ -z "$APP_HOME" ];then
  PRG="$0"
  while [ -h "$PRG" ] ; do
    ls=$(ls -ld "$PRG")
    link=$(expr "$ls" : '.*-> \(.*\)$')
    if expr "$link" : '/.*' > /dev/null; then
      PRG="$link"
    else
      PRG=$(dirname "$PRG")/"$link"
    fi
  done
  cd "$(dirname "$PRG")/.." || exit 1
  export APP_HOME="$(pwd)"
  cd - &>/dev/null || exit 1
fi


export REMOTE_USER=ledgermaster

export WORKSPACE=/mnt/data2/ledgermaster-workspace
export N_PARTITIONS=1
export LEDGER_NAME=lottery


export CHAIN=opusmchain

# Local system path
export DIR_BIN=$APP_HOME/bin
export DIR_SBIN=$APP_HOME/sbin
export DIR_CONF=$APP_HOME/conf
export DIR_EXT=$APP_HOME/ext
export DIR_CLUSTER=$APP_HOME/cluster
export FILE_NODES=$DIR_CONF/nodes

# External software
export GETH_TAR_NAME=quorum.tar.gz
export ETHSTATS_TAR_NAME=ethstats.tar.gz
export MESOS_TAR_NAME=mesos-1.9.0.tar.gz

export NODES=(`grep -v -e '^[[:space:]]*$' $FILE_NODES`)

export BASE_DIR=/mnt/data1
export CHAIN0_BASE_DIR=/mnt/data1
export CHAIN1_BASE_DIR=/mnt/data1

# ZooKeeper
export ZOOKEEPER_TAR_FILE=apache-zookeeper-3.5.8-bin.tar.gz
export ZOOKEEPER_CLIENT_PORT=2181

# Hadoop
export HADOOP_TAR_FILE=hadoop-3.3.0-aarch64.tar.gz
export HADOOP_NAMENODE_PORT=9000
export HADOOP_CORE_SITE=core-site.xml
export HADOOP_HDFS_SITE=hdfs-site.xml

# Kafka
export KAFKA_TAR_FILE=kafka_2.13-2.6.0.tgz
export KAFKA_BIN_DIR=$BASE_DIR/kafka/bin
export KAFKA_CONSUMER_GROUP=OPUSM_LEDGER
export KAFKA_PORT=39092

# Spark
export SPARK_TAR_FILE=spark-3.0.1-bin-hadoop3.2.tgz

# EtherStats
export ETHSTAT_HOME=$BASE_DIR/ethstat
export ETHSTAT_PORT=8500
export ETHSTAT_WS_SECRET=aAkf8dIs1m

# Quorum
export FILE_GENESIS=$DIR_CONF/genesis.json
export GETH_PORT_BASE=21000
export GETH_RPC_PORT_BASE=22000
export GETH_RAFT_PORT_BASE=50000

# Reconcilement
export RECONCILEMENT_HOME=$BASE_DIR/reconcilement-server
export N_PRIVATEKEY=1

export LOTTERY_DRAW=("P_P6" "P_P1" "P_P3" "P_ATOF" "P_P4" "BINGO" "P10" "P9" "P8" "P7" "P6" "P5" "P4" "P3" "P2" "SUM")
export LOTTERY_INST=("CATCH" "S_CATCH" "DJACK" "S_DJACK" "THUNT" "S_THUNT" "TLUCK" "S_TLUCK")
export LOTTERY_PENSION=("P720")

################################################################################
# Utilities
function join_by {
  local IFS=$1
  shift
  echo "$*"
}

function clean-workspace {
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    ssh $REMOTE_USER@$NODE "rm -rf $WORKSPACE"
  done
}

function prepare {
  NODE=$1
  DIR_PATH=$2
  ssh $REMOTE_USER@$NODE "rm -rf $DIR_PATH ; mkdir -p $DIR_PATH" > /dev/null
}

################################################################################
# ZooKeeper
function install-zookeeper-server {
  NODE=$1
  ZOOKEEPER_HOME=$2
  prepare $NODE $ZOOKEEPER_HOME
  scp $DIR_EXT/$ZOOKEEPER_TAR_FILE $REMOTE_USER@$NODE:$ZOOKEEPER_HOME >/dev/null
  ssh $REMOTE_USER@$NODE "tar -xf $ZOOKEEPER_HOME/$ZOOKEEPER_TAR_FILE --strip-components=1 -C $ZOOKEEPER_HOME && rm -f $ZOOKEEPER_HOME/bin/*.cmd" >/dev/null
}
function start-zookeeper-server {
  NODE=$1
  ZOOKEEPER_HOME=$2
  ZOOKEEPER_CONFIG=$3
  ssh $REMOTE_USER@$NODE "nohup $ZOOKEEPER_HOME/bin/zkServer.sh start $ZOOKEEPER_CONFIG" >>/dev/null 2>&1
}
function stop-zookeeper-server {
  NODE=$1
  ZOOKEEPER_HOME=$2
  ZOOKEEPER_CONFIG=$3
  ssh $REMOTE_USER@$NODE "$ZOOKEEPER_HOME/bin/zkServer.sh stop $ZOOKEEPER_CONFIG" >>/dev/null 2>&1
}

function install-zookeeper {
  ZOOKEEPER_HOME=$WORKSPACE/zookeeper
  ZOOKEEPER_CONFIG=$ZOOKEEPER_HOME/conf/zookeeper-$LEDGER_NAME.cfg
  ZOOKEEPER_DATA_DIR=$ZOOKEEPER_HOME/data/zookeeper-$LEDGER_NAME
  LINES=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    LINES[$iNode]="server.$iNode=${NODES[$iNode]}:2888:3888"
  done
  PIDS=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    install-zookeeper-server $NODE $ZOOKEEPER_HOME &
    PIDS+=($!)
  done

  for PID in ${PIDS[@]}; do
    wait $PID
  done
    
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    ZOOKEEPER_SERVERS=""
    for ((j=0 ; j<${#NODES[@]} ; ++j )); do
      if [ "$iNode" == "$j" ]; then
        ZOOKEEPER_SERVERS="$ZOOKEEPER_SERVERS"$'\n'"server.$iNode=0.0.0.0:2888:3888"
      else
        ZOOKEEPER_SERVERS="$ZOOKEEPER_SERVERS"$'\n'"${LINES[$j]}"
      fi
    done
    cat <<EOF | ssh $REMOTE_USER@$NODE "cat > $ZOOKEEPER_CONFIG"
dataDir=$ZOOKEEPER_DATA_DIR
clientPort=$ZOOKEEPER_CLIENT_PORT
maxClientCnxns=0
admin.enableServer=false

initLimit=10
syncLimit=5

$ZOOKEEPER_SERVERS
EOF
    prepare $NODE $ZOOKEEPER_DATA_DIR
    ssh $REMOTE_USER@$NODE "echo $iNode > $ZOOKEEPER_DATA_DIR/myid"
  done
}

function start-zookeeper {
  ZOOKEEPER_HOME=$WORKSPACE/zookeeper
  ZOOKEEPER_CONFIG=$ZOOKEEPER_HOME/conf/zookeeper-$LEDGER_NAME.cfg
  ZOOKEEPER_DATA_DIR=$ZOOKEEPER_HOME/data/zookeeper-$LEDGER_NAME
  PIDS=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    start-zookeeper-server $NODE $ZOOKEEPER_HOME $ZOOKEEPER_CONFIG &
    PIDS+=($!)
  done

  for PID in ${PIDS[@]}; do
    wait $PID
  done
}

function stop-zookeeper {
  ZOOKEEPER_HOME=$WORKSPACE/zookeeper
  ZOOKEEPER_CONFIG=$ZOOKEEPER_HOME/conf/zookeeper-$LEDGER_NAME.cfg
  ZOOKEEPER_DATA_DIR=$ZOOKEEPER_HOME/data/zookeeper-$LEDGER_NAME
  PIDS=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    stop-zookeeper-server $NODE $ZOOKEEPER_HOME $ZOOKEEPER_CONFIG &
    PIDS+=($!)
  done

  for PID in ${PIDS[@]}; do
    wait $PID
  done
}

################################################################################
# Geth
function install-geth-node {
  NETWORK_ID=$1
  NODE=$2
  GROUP_NAME=$3
  NAME=$4
  GETH_HOME=$WORKSPACE/geth-$NAME
  GETH_PORT=$5
  GETH_RPC_PORT=$6
  GETH_RAFT_PORT=$7

  GETH_BIN=$GETH_HOME/bin
  GETH_DATA=$GETH_HOME/data
  GETH_LOG=$GETH_HOME/log/node.log
  FILE_NODEKEY=$DIR_CLUSTER/nodekey-$NAME
  FILE_ENODE=$DIR_CLUSTER/enode-$NAME
  FILE_STATIC_NODES=$DIR_CLUSTER/static-nodes-$GROUP_NAME.json

  prepare $NODE $GETH_HOME
  if [ -z "$8" ]; then 
    scp $DIR_EXT/$GETH_TAR_NAME $REMOTE_USER@$NODE:$GETH_HOME >/dev/null
    ssh $REMOTE_USER@$NODE "tar -xf $GETH_HOME/$GETH_TAR_NAME --strip-components=1 -C $GETH_HOME"
  else
    ssh $REMOTE_USER@$NODE "tar -xf $WORKSPACE/geth-$8/$GETH_TAR_NAME --strip-components=1 -C $GETH_HOME"
  fi
  prepare $NODE $GETH_HOME/log
  prepare $NODE $GETH_DATA/geth
  ssh $REMOTE_USER@$NODE "cat >> $GETH_HOME/bin/env.sh" <<EOF
NODE=$NODE
GETH_DATA=$GETH_DATA
GETH_LOG=$GETH_LOG
GETH_PORT=$GETH_PORT
GETH_RPC_PORT=$GETH_RPC_PORT
GETH_RAFT_PORT=$GETH_RAFT_PORT
NETWORK_ID=$NETWORK_ID
RAFT_BLOCKTIME=200
EOF
  scp -r $FILE_GENESIS $REMOTE_USER@$NODE:$GETH_DATA/genesis.json >/dev/null
  scp -r $FILE_NODEKEY $REMOTE_USER@$NODE:$GETH_DATA/geth/nodekey >/dev/null
  scp -r $FILE_ENODE $REMOTE_USER@$NODE:$GETH_DATA/enode >/dev/null
  scp -r $FILE_STATIC_NODES $REMOTE_USER@$NODE:$GETH_DATA/static-nodes.json >/dev/null
  ssh $REMOTE_USER@$NODE "$GETH_BIN/geth --datadir $GETH_DATA init $GETH_DATA/genesis.json" >/dev/null 2>&1
}
function start-geth-node {
  NODE=$1
  GETH_HOME=$2
  ssh $REMOTE_USER@$NODE "$GETH_HOME/bin/start-geth" >> /dev/null 2>&1
}
function stop-geth-node {
  NODE=$1
  GETH_HOME=$2
  ssh $REMOTE_USER@$NODE "$GETH_HOME/bin/stop-geth" >> /dev/null 2>&1
}

function create-nodekey {
  NAME=$1
  $DIR_BIN/bootnode --genkey=$DIR_CLUSTER/nodekey-$NAME
  $DIR_BIN/bootnode --nodekey=$DIR_CLUSTER/nodekey-$NAME --writeaddress > $DIR_CLUSTER/enode-$NAME
}


function create-static-nodes {
  NAME=$1
  GETH_PORT=$2
  GETH_RAFT_PORT=$3
  LINES=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    ENODE=`cat $DIR_CLUSTER/enode-$NAME-$iNode`
    LINES[$iNode]="\"enode://$ENODE@${NODES[$iNode]}:$GETH_PORT?discport=0&raftport=$GETH_RAFT_PORT\""
  done

  CONTENT=`join_by ',' ${LINES[*]}`
  if which jq >>/dev/null 2>&1 ; then
    echo "[ $CONTENT ]" | jq > $DIR_CLUSTER/static-nodes-$NAME.json
  else
    echo "[ $CONTENT ]" > $DIR_CLUSTER/static-nodes-$NAME.json
  fi
}

function install-geth {
  rm -rf $DIR_CLUSTER
  mkdir -p $DIR_CLUSTER
  zkCli.sh -server ${NODES[0]}:$ZOOKEEPER_CLIENT_PORT >>/dev/null 2>&1 <<EOF

  create /partitions
  create /chains
EOF
  for (( iPartition=0 ; iPartition<$N_PARTITIONS ; ++iPartition )); do
    zkCli.sh -server ${NODES[0]}:$ZOOKEEPER_CLIENT_PORT >>/dev/null 2>&1 <<EOF
    
    create /partitions/$iPartition
    create /chains/$((20210101 + $iPartition))
EOF
    for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
      NODE=${NODES[$iNode]}
      zkCli.sh -server ${NODES[0]}:$ZOOKEEPER_CLIENT_PORT >>/dev/null 2>&1 <<EOF
      create /chains/$((20210101 + $iPartition))/$iNode   http://$NODE:$(($GETH_RPC_PORT_BASE + $iPartition))
EOF
      create-nodekey $LEDGER_NAME-$iPartition-$iNode ${NODES[$iNode]}
    done

    create-static-nodes $LEDGER_NAME-$iPartition $(($GETH_PORT_BASE + $iPartition)) $(($GETH_RAFT_PORT_BASE + $iPartition))

    PIDS=()
    for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
      if [ $iPartition -eq 0 ]; then
        install-geth-node $((20210101 + $iPartition)) ${NODES[$iNode]} $LEDGER_NAME-$iPartition $LEDGER_NAME-$iPartition-$iNode $(($GETH_PORT_BASE + $iPartition)) $(($GETH_RPC_PORT_BASE + $iPartition)) $(($GETH_RAFT_PORT_BASE + $iPartition)) &
        PIDS+=($!)
      else
        install-geth-node $((20210101 + $iPartition)) ${NODES[$iNode]} $LEDGER_NAME-$iPartition $LEDGER_NAME-$iPartition-$iNode $(($GETH_PORT_BASE + $iPartition)) $(($GETH_RPC_PORT_BASE + $iPartition)) $(($GETH_RAFT_PORT_BASE + $iPartition)) $LEDGER_NAME-0-$iNode &
        PIDS+=($!)
      fi

    done
    for PID in ${PIDS[@]}; do
      wait $PID
    done


  done
}

function start-geth {
  PIDS=()
  for (( iPartition=0 ; iPartition<$N_PARTITIONS ; ++iPartition )); do
    for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
      NODE=${NODES[$iNode]}
      GETH_HOME=$WORKSPACE/geth-$LEDGER_NAME-$iPartition-$iNode
      start-geth-node $NODE $GETH_HOME &
      PIDS+=($!)
    done
  done
  for PID in ${PIDS[@]}; do
    wait $PID
  done
}
function stop-geth {
  PIDS=()
  for (( iPartition=0 ; iPartition<$N_PARTITIONS ; ++iPartition )); do
    for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
      NODE=${NODES[$iNode]}
      GETH_HOME=$WORKSPACE/geth-$LEDGER_NAME-$iPartition-$iNode
      stop-geth-node $NODE $GETH_HOME &
      PIDS+=($!)
    done
  done
  for PID in ${PIDS[@]}; do
    wait $PID
  done
}

################################################################################
# LedgerMaster Table

function create-table {
  XML_PATH=$1
  rm -rf $APP_HOME/data
  $APP_HOME/bin/migrator -c $XML_PATH
}

function create-tables {
  zkCli.sh -server ${NODES[0]}:$ZOOKEEPER_CLIENT_PORT >>/dev/null 2>&1 <<EOF
  deleteall /tables
  create /tables
EOF
  for (( iPartition=0 ; iPartition<$N_PARTITIONS ; ++iPartition )); do
    export ENDPOINT=http://${NODES[0]}:$(($GETH_RPC_PORT_BASE + $iPartition))
    CHANGELOG_FILE=$DIR_CLUSTER/changelog-$LEDGER_NAME-$iPartition.xml
    envsubst < $DIR_CONF/changelog-template.xml > $CHANGELOG_FILE
    create-table $CHANGELOG_FILE | {
      while IFS= read -r LINE; do
        NAME=$(echo $LINE | cut -f 1 -d ':')
        if [ "$NAME" != "Ledger" ]; then
          ADDRESS=$(echo $LINE | cut -f 2 -d ':')
          zkCli.sh -server ${NODES[0]}:$ZOOKEEPER_CLIENT_PORT >>/dev/null 2>&1 <<EOF
          create /tables/$NAME
          create /tables/$NAME/partitions
          create /tables/$NAME/partitions/$iPartition
          create /tables/$NAME/partitions/$iPartition/chain           $((20210101 + $iPartition))
          create /tables/$NAME/partitions/$iPartition/address         $ADDRESS
EOF
        fi
      done
    }
  done
  NODE=${NODES[0]}
  zkCli.sh -server $NODE:$ZOOKEEPER_CLIENT_PORT >>/dev/null 2>&1 <<EOF
  create /tables/tb_draw_issue
  create /tables/tb_draw_issue/indices
  create /tables/tb_draw_issue/indices/group
  create /tables/tb_draw_issue/columns                  order_id,group,user_serial,user_pin,pick_no,issue_req_hms
  create /tables/tb_inst_issue
  create /tables/tb_inst_issue/indices
  create /tables/tb_inst_issue/indices/group
  create /tables/tb_inst_issue/columns                  order_id,group,user_serial,user_pin,game_data,issue_req_hms
  create /tables/tb_pension_issue
  create /tables/tb_pension_issue/indices
  create /tables/tb_pension_issue/indices/group
  create /tables/tb_pension_issue/columns               order_id,group,user_serial,user_pin,pick_no,issue_req_hms
  create /tables/tb_draw_win
  create /tables/tb_draw_win/indices
  create /tables/tb_draw_win/indices/group
  create /tables/tb_draw_win/columns                    order_id,group,user_serial,user_pin,pick_no,rank_id,issue_req_hms
  create /tables/tb_inst_win
  create /tables/tb_inst_win/indices
  create /tables/tb_inst_win/indices/group
  create /tables/tb_inst_win/columns                    order_id,group,user_serial,user_pin,game_data,issue_req_hms
  create /tables/tb_pension_win
  create /tables/tb_pension_win/indices
  create /tables/tb_pension_win/indices/group
  create /tables/tb_pension_win/columns                 order_id,group,user_serial,user_pin,pick_no,rank_id,issue_req_hms
EOF
}


################################################################################
# Kafka
function stop-kafka-broker {
  NODE=$1
  KAFKA_HOME=$2
  ssh $REMOTE_USER@$NODE $KAFKA_HOME/bin/kafka-server-stop.sh
}

function start-kafka-broker {
  NODE=$1
  KAFKA_HOME=$2
  NAME=$3
  KAFKA_CONFIG=$KAFKA_HOME/config/ledgermaster-$NAME.properties
  ssh $REMOTE_USER@$NODE $KAFKA_HOME/bin/kafka-server-start.sh -daemon $KAFKA_CONFIG
}

function install-kafka-broker {
  NODE=$1
  KAFKA_HOME=$2
  NAME=$3
  KAFKA_BROKER_ID=$4
  KAFKA_CONFIG=$KAFKA_HOME/config/ledgermaster-$NAME.properties
  KAFKA_LOG_DIR=$KAFKA_HOME/data/ledgermaster-$NAME
  prepare $NODE $KAFKA_HOME
  scp $DIR_EXT/$KAFKA_TAR_FILE $REMOTE_USER@$NODE:$KAFKA_HOME
  ssh $REMOTE_USER@$NODE "tar -xf $KAFKA_HOME/$KAFKA_TAR_FILE --strip-components=1 -C $KAFKA_HOME"
  cat <<EOF | ssh $REMOTE_USER@$NODE "cat > $KAFKA_CONFIG"
broker.id=$KAFKA_BROKER_ID
listeners=PLAINTEXT://:$KAFKA_PORT

num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600

log.dirs=$KAFKA_LOG_DIR
num.partitions=1
num.recovery.threads.per.data.dir=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
zookeeper.connect=localhost:$ZOOKEEPER_CLIENT_PORT/kafka
zookeeper.connection.timeout.ms=18000
group.initial.rebalance.delay.ms=0
EOF
}

function start-kafka {
  PIDS=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    start-kafka-broker $NODE $WORKSPACE/kafka $LEDGER_NAME >/dev/null 2>&1 &
    PIDS+=($!)
  done
  for PID in ${PIDS[@]}; do
    wait $PID
  done
}
function stop-kafka {
  PIDS=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    stop-kafka-broker $NODE $WORKSPACE/kafka >/dev/null 2>&1 &
    PIDS+=($!)
  done
  for PID in ${PIDS[@]}; do
    wait $PID
  done
}
function install-kafka {
  PIDS=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    install-kafka-broker $NODE $WORKSPACE/kafka $LEDGER_NAME $iNode >/dev/null 2>&1 &
    PIDS+=($!)
  done
  for PID in ${PIDS[@]}; do
    wait $PID
  done
}
function configure-channel {
  NODE=${NODES[0]}
  CHANNELS=("DHLOTTO_real_pdc" "DHLOTTO_real_pdc2" "DHPENSION_oppdc" "DHLOTTO_WIN_real_pdc" "DHLOTTO_WIN_real_pdc2" "DHPENSION_WIN_real_pdc" "DHPENSION_WIN_real_pdc2")
  for (( iChannel=0 ; iChannel<${#CHANNELS[@]} ; ++iChannel )); do
    CHANNEL_NAME=${CHANNELS[$iChannel]}
    kafka-topics.sh --bootstrap-server $NODE:$KAFKA_PORT --create --topic $CHANNEL_NAME --partitions 1 --config min.insync.replicas=2 --replication-factor 3
    zkCli.sh -server $NODE:$ZOOKEEPER_CLIENT_PORT >>/dev/null 2>&1 <<EOF
    create /channels
    create /channels/$CHANNEL_NAME
    create /channels/$CHANNEL_NAME/http       true
    create /channels/$CHANNEL_NAME/kafka      true
EOF
  done
}

################################################################################
# Hadoop
function install-hadoop-node {
  NODE=$1
  HADOOP_HOME=$2
  MASTER=$3
  prepare $NODE $HADOOP_HOME
  scp $DIR_EXT/$HADOOP_TAR_FILE $REMOTE_USER@$NODE:$HADOOP_HOME >/dev/null
  ssh $REMOTE_USER@$NODE "tar -xf $HADOOP_HOME/$HADOOP_TAR_FILE --strip-components=1 -C $HADOOP_HOME && rm -f $HADOOP_HOME/bin/*.cmd" >/dev/null

  cat <<EOF | ssh $REMOTE_USER@$NODE "cat > $HADOOP_HOME/etc/hadoop/$HADOOP_CORE_SITE"
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property>
    <name>fs.default.name</name>
    <value>hdfs://$MASTER:$HADOOP_NAMENODE_PORT</value>
  </property>
</configuration>
EOF

  cat <<EOF | ssh $REMOTE_USER@$NODE "cat > $HADOOP_HOME/etc/hadoop/$HADOOP_HDFS_SITE"
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property>
    <name>dfs.replication</name>
    <value>3</value>
  </property>
  <property>
    <name>dfs.permissions.enabled</name>
    <value>false</value>
  </property>
  <property>
    <name>dfs.namenode.name.dir</name>
    <value>file://$HADOOP_HOME/namenode</value>
  </property>

  <property>
    <name>dfs.datanode.data.dir</name>
    <value>file://$HADOOP_HOME/datanode</value>
  </property>
</configuration>
EOF
}

function format-hdfs {
  NODE=$1
  HADOOP_HOME=$2

  ssh $REMOTE_USER@$NODE "$HADOOP_HOME/bin/hdfs namenode -format ledgermaster" >/dev/null
}

function start-hadoop-namenode {
  NODE=$1
  HADOOP_HOME=$2

  ssh $REMOTE_USER@$NODE "$HADOOP_HOME/bin/hdfs --daemon start namenode" >/dev/null
}

function start-hadoop-datanode {
  NODE=$1
  HADOOP_HOME=$2

  ssh $REMOTE_USER@$NODE "$HADOOP_HOME/bin/hdfs --daemon start datanode" >/dev/null
}
function stop-hadoop-namenode {
  NODE=$1
  HADOOP_HOME=$2

  ssh $REMOTE_USER@$NODE "$HADOOP_HOME/bin/hdfs --daemon stop namenode" >/dev/null
}

function stop-hadoop-datanode {
  NODE=$1
  HADOOP_HOME=$2

  ssh $REMOTE_USER@$NODE "$HADOOP_HOME/bin/hdfs --daemon stop datanode" >/dev/null
}

function install-hadoop {
  PIDS=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    install-hadoop-node $NODE $WORKSPACE/hadoop ${NODES[0]} >/dev/null 2>&1 &
    PIDS+=($!)
  done
  for PID in ${PIDS[@]}; do
    wait $PID
  done
  format-hdfs ${NODES[0]} $WORKSPACE/hadoop

}

function stop-hadoop {
  PIDS=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    stop-hadoop-datanode $NODE $WORKSPACE/hadoop ${NODES[$iNode]} >/dev/null 2>&1 &
    PIDS+=($!)
  done
  for PID in ${PIDS[@]}; do
    wait $PID
  done
  stop-hadoop-namenode ${NODES[0]} $WORKSPACE/hadoop >/dev/null 2>&1
}


function start-hadoop {
  start-hadoop-namenode ${NODES[0]} $WORKSPACE/hadoop >/dev/null 2>&1
  PIDS=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    start-hadoop-datanode $NODE $WORKSPACE/hadoop ${NODES[$iNode]} >/dev/null 2>&1 &
    PIDS+=($!)
  done
  for PID in ${PIDS[@]}; do
    wait $PID
  done
}

################################################################################
# Mesos
function install-mesos-agent {
  NODE=$1
  MESOS_HOME=$2
  N_QUORUM=$3
  ssh $REMOTE_USER@$NODE "echo $N_QUORUM | sudo tee /etc/mesos-master/quorum" >/dev/null
  echo $NODE |ssh $REMOTE_USER@$NODE "sudo tee /etc/mesos-master/hostname" >/dev/null
}

function stop-mesos-agent {
  NODE=$1
  ssh $REMOTE_USER@$NODE "sudo systemctl stop mesos-slave"
  ssh $REMOTE_USER@$NODE "sudo systemctl stop mesos-master"
}

function start-mesos-agent {
  NODE=$1
  ssh $REMOTE_USER@$NODE "sudo systemctl start mesos-slave"
  ssh $REMOTE_USER@$NODE "sudo systemctl start mesos-master"
}

function install-mesos {
  PIDS=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    install-mesos-agent $NODE $WORKSPACE/mesos $((${#NODES[@]} / 2 + 1)) >/dev/null 2>&1 &
    PIDS+=($!)
  done
  for PID in ${PIDS[@]}; do
    wait $PID
  done
}

function stop-mesos {
  PIDS=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    stop-mesos-agent $NODE >/dev/null 2>&1 &
    PIDS+=($!)
  done
  for PID in ${PIDS[@]}; do
    wait $PID
  done
}

function start-mesos {
  PIDS=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    start-mesos-agent $NODE >/dev/null 2>&1 &
    PIDS+=($!)
  done
  for PID in ${PIDS[@]}; do
    wait $PID
  done
}



################################################################################
# Spark
function install-spark-executor {
  NODE=$1
  SPARK_HOME=$2
  prepare $NODE $SPARK_HOME
  scp $DIR_EXT/$SPARK_TAR_FILE $REMOTE_USER@$NODE:$SPARK_HOME >/dev/null
  ssh $REMOTE_USER@$NODE "tar -xf $SPARK_HOME/$SPARK_TAR_FILE --strip-components=1 -C $SPARK_HOME && rm -f $SPARK_HOME/bin/*.cmd" >/dev/null

}
function install-spark {
  PIDS=()
  for (( iNode=0 ; iNode<${#NODES[@]} ; ++iNode )); do
    NODE=${NODES[$iNode]}
    install-spark-executor $NODE $WORKSPACE/spark
    PIDS+=($!)
  done
  for PID in ${PIDS[@]}; do
    wait $PID
  done

  zkCli.sh -server $NODE:$ZOOKEEPER_CLIENT_PORT >>/dev/null 2>&1 <<EOF
  create /spark
  create /spark/cluster               mesos://node3.opusm.io:5050
  create /spark/executor
  create /spark/executor/home         /mnt/data2/ledgermaster-workspace/spark
EOF
}

################################################################################
# Agent
function configure-processor {
  NODE=${NODES[0]}
  zkCli.sh -server $NODE:$ZOOKEEPER_CLIENT_PORT >>/dev/null 2>&1 <<EOF
  create /processors
  create /processors/draw_issue
  create /processors/draw_issue/class                    dhlottery.processor.DrawLotteryIssueProcessor
  create /processors/draw_issue/channels                 DHLOTTO_real_pdc,DHLOTTO_real_pdc2
  create /processors/inst_issue
  create /processors/inst_issue/class                    dhlottery.processor.InstantLotteryIssueProcessor
  create /processors/inst_issue/channels                 DHLOTTO_real_pdc,DHLOTTO_real_pdc2
  create /processors/pension_issue
  create /processors/pension_issue/class                 dhlottery.processor.PensionLotteryIssueProcessor
  create /processors/pension_issue/channels              DHPENSION_oppdc
  create /processors/draw_win
  create /processors/draw_win/class                      dhlottery.processor.DrawLotteryWinProcessor
  create /processors/draw_win/channels                   DHLOTTO_WIN_real_pdc,DHLOTTO_WIN_real_pdc2
  create /processors/inst_win
  create /processors/inst_win/class                      dhlottery.processor.InstantLotteryWinProcessor
  create /processors/inst_win/channels                   DHLOTTO_real_pdc,DHLOTTO_real_pdc2
  create /processors/pension_win
  create /processors/pension_win/class                   dhlottery.processor.PensionLotteryWinProcessor
  create /processors/pension_win/channels                DHPENSION_WIN_real_pdc,DHPENSION_WIN_real_pdc2
  create /queries
  create /queries/8e3b6c08                               dhlottery.processor.SelectByUserSerial
EOF
}

function configure-metastore {
  zkCli.sh -server $NODE:$ZOOKEEPER_CLIENT_PORT >>/dev/null 2>&1 <<EOF
  create /metastore
  create /metastore/driver         com.mysql.jdbc.Driver
  create /metastore/url            jdbc:mysql://dev.opusm.io:3306/lottery_metastore?characterEncoding=UTF-8&serverTimezone=UTC
  create /metastore/username       ledgermaster
  create /metastore/password       nwKh,7we
EOF
}
