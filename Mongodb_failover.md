## Implementation of MongoDb on Ubuntu22.04

The critical changes :

1. Trigger a failure 

   Pause from JetPack, but we should kill the leader MongoDb leader instance

2. Mongodb_connection _thread_pool

   It’s unnecessary, weird and makes evaluation complicated; we create too many threads (2000s) and then each one have a queue to process a request!

   `void MongodbHandler(int thread_id)` do the work!

3. Jetpack → forward requests to the underlying MongoDb
   
   Current implementation has fixed leader, but we should implement a forward semantics

4. Jetpack waits on a signal 

   When MongoDb a new leader elected, send a signal via file

   TODO: impelment an util c++ header that can be included by JetPack and us

5. MongoDb waits for a signal from Jetpack

   When Jetpack finishes its leader election, send a signal back to the MongoDb 

6. MongoDb new leader election


## Code pieces

`TxLogServer::JetpackStatus::RECOVERY`: status
