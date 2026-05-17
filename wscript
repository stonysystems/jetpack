#!/usr/bin/env python3
APPNAME="janus"
VERSION="0.0"

import os
import sys
import glob
from waflib import Logs
from waflib import Options

pargs = ['--cflags', '--libs']
#BOOST_LIBS = 'BOOST_SYSTEM BOOST_FILESYSTEM BOOST_THREAD BOOST_COROUTINE'

#g++ -Wall -Wextra -std=c++17 -ggdb -Iinclude -Ilib -I/usr/local/include/mongocxx/v_noabi -I/usr/local/include/bsoncxx/v_noabi -Llib main.cpp -o bin/main -lboost_system -lpthread -lcrypto -lssl -lmongocxx -lbsoncxx

def options(opt):
    opt.load("compiler_c")
    opt.load("compiler_cxx")
    opt.load(['boost', 'unittest_gtest'],
             tooldir=['.waf-tools'])
    opt.add_option('-g', '--use-gxx', dest='cxx',
                   default=False, action='store_true')
    opt.add_option('-c', '--use-clang', dest='clang',
                   default=False, action='store_true')
    opt.add_option('-i', '--use-ipc', dest='ipc',
                   default=False, action='store_true')
    opt.add_option('-p', '--enable-profiling', dest='prof',
                   default=False, action='store_true')
    opt.add_option('', '--enable-event-timeout', dest='event_timeout',
                   default=False, action='store_true')
    opt.add_option('-d', '--debug', dest='debug',
                   default=False, action='store_true')
    opt.add_option('-M', '--enable-tcmalloc', dest='tcmalloc',
                   default=False, action='store_true')
    opt.add_option('-J', '--enable-jemalloc', dest='jemalloc',
                   default=False, action='store_true')
    opt.add_option('-s', '--enable-rpc-statistics', dest='rpc_s',
                   default=False, action='store_true')
    opt.add_option('-P', '--enable-piece-count', dest='pc',
                   default=False, action='store_true')
    opt.add_option('-C', '--enable-conflict-count', dest='cc',
                   default=False, action='store_true')
    opt.add_option('-C', '--disable-reuse-coroutine', dest='disable_reuse_coroutine',
                   default=False, action='store_true')
    opt.add_option('-r', '--enable-logging', dest='log',
                   default=False, action='store_true')
    opt.add_option('-T', '--enable-txn-stat', dest='txn_stat',
                   default=False, action='store_true')
    opt.add_option('-D', '--disable-check-python', dest='disable_check_python',
                   default=False, action='store_true')
    opt.add_option('-m', '--enable-mutrace-debug', dest='mutrace',
                   default=False, action='store_true')
    opt.add_option('-W', '--simulate-wan', dest='simulate_wan',
                   default=False, action='store_true')
    opt.add_option('-S', '--db-checksum', dest='db_checksum',
                   default=False, action='store_true')
    opt.add_option('-L', '--enable-leaksan', dest='leaksan',
                   default=False, action='store_true')
    opt.add_option('', '--skip-txn-server', dest='skip_txn_server',
                   default=False, action='store_true')
    opt.add_option('','--enable-raft-test',dest='enable_raft_test',
                   default=False, action='store_true')
    opt.add_option('','--disable-raft-batch', dest='disable_raft_batch',
                   default=False, action='store_true',
                   help='Define RAFT_BATCH_OFF so RAFT_BATCH_OPTIMIZATION is not set in constants.h.')
    opt.add_option('','--disable-raft-pipeline', dest='disable_raft_pipeline',
                   default=False, action='store_true',
                   help='Define RAFT_PIPELINE_OFF so RAFT_PIPELINE_OPTIMIZATION is not set in constants.h.')
    opt.add_option('','--raft-pipeline-cap', dest='raft_pipeline_cap',
                   default=None, type='int',
                   help='Override kMaxInFlightPerFollower (default 8000). Defines RAFT_PIPELINE_CAP=N for the build.')
    opt.add_option('','--enable-jetpack-prof', dest='enable_jetpack_prof',
                   default=False, action='store_true',
                   help='Define JETPACK_PROF=1 to enable per-stage timing counters in scheduler / service / coordinator hot paths. Production builds should leave this off (zero overhead when undefined).')
    opt.add_option('','--enable-mongodb-no-journal', dest='enable_mongodb_no_journal',
                   default=False, action='store_true',
                   help='Define MONGODB_NO_JOURNAL=1 so the mongocxx client URI carries journal=false instead of journal=true. Mongodb 7+ requires journal at the server, so this is the only fsync-off-equivalent knob: writes ack before the server has flushed the journal.')
    opt.add_option('','--enable-etcd-raw-grpc', dest='enable_etcd_raw_grpc',
                   default=False, action='store_true',
                   help='Define JANUS_ETCD_USE_RAW_GRPC=1 to bypass etcd-cpp-apiv3 / cpprestsdk / pplx for the etcd KV hot path and talk directly to etcdserverpb via grpc++. The leader watcher still uses etcd-cpp-apiv3. Requires the etcdserverpb generated stubs at third_party/etcd-cpp-apiv3/build/proto/gen/proto/ (built when etcd-cpp-apiv3 itself is built).')
    opt.parse_args();

def configure(conf):
    _choose_compiler(conf)
    _enable_pic(conf)
    conf.load("compiler_c")
    conf.load("compiler_cxx unittest_gtest")
    conf.load("boost")

    _enable_tcmalloc(conf)
    _enable_jemalloc(conf)
    _enable_cxx14(conf)
    _enable_debug(conf)
    _enable_profile(conf)
    _enable_event_timeout(conf)
    _enable_ipc(conf)
    _enable_rpc_s(conf)
    _enable_piece_count(conf)
    _enable_txn_count(conf)
    _enable_conflict_count(conf)
    _enable_raft_test(conf)
#    _enable_snappy(conf)
    #_enable_logging(conf)
    _enable_reuse_coroutine(conf)
    _enable_simulate_wan(conf)
    _enable_db_checksum(conf)
    _enable_leaksan(conf)

    conf.env.append_value("CXXFLAGS", "-Wno-reorder")
    conf.env.append_value("CXXFLAGS", "-Wno-comment")
    conf.env.append_value("CXXFLAGS", "-Wno-unused-function")
    conf.env.append_value("CXXFLAGS", "-Wno-unused-variable")
    conf.env.append_value("CXXFLAGS", "-Wno-sign-compare")
    conf.check_boost(lib='system filesystem context thread coroutine')

    conf.env.append_value("CXXFLAGS", "-Wno-sign-compare")
    conf.env.append_value('INCLUDES', ['/usr/local/include', os.path.expanduser('~/.local/include')])
#    conf.check_cxx(lib='boost_system', use='BOOST_SYSTEM')
#    conf.check_cxx(lib='boost_filesystem', use='BOOST_FILESYSTEM')
#    conf.check_cxx(lib='boost_coroutine', use='BOOST_COROUTINE')

    # in case you use linuxbrew, uncomment the following 
#    conf.env.append_value('INCLUDES', [os.path.expanduser('~') + '/.linuxbrew/include'])
#    conf.env.append_value('LIBPATH', [os.path.expanduser('~') + '/.linuxbrew/lib'])
    conf.env.LIB_PTHREAD = 'pthread'
    conf.check_cfg(package='yaml-cpp', uselib_store='YAML-CPP', args=pargs)

    if sys.platform != 'darwin':
        conf.env.LIB_RT = 'rt'

    if Options.options.disable_check_python:
        pass
    else:
        conf.load("python")
        conf.check_python_headers()
        # check python modules
#        conf.check_python_module('tabulate')
#        conf.check_python_module('yaml')

    if Options.options.skip_txn_server:
        conf.env.append_value("CXXFLAGS", "-DSKIP_TXN_SERVER")

    if Options.options.disable_raft_batch:
        conf.env.append_value("CXXFLAGS", "-DRAFT_BATCH_OFF")
    if Options.options.disable_raft_pipeline:
        conf.env.append_value("CXXFLAGS", "-DRAFT_PIPELINE_OFF")
    if Options.options.raft_pipeline_cap is not None:
        conf.env.append_value("CXXFLAGS",
                              "-DRAFT_PIPELINE_CAP=%d" % Options.options.raft_pipeline_cap)
    if Options.options.enable_jetpack_prof:
        conf.env.append_value("CXXFLAGS", "-DJETPACK_PROF=1")
    if Options.options.enable_mongodb_no_journal:
        conf.env.append_value("CXXFLAGS", "-DMONGODB_NO_JOURNAL=1")
    if Options.options.enable_etcd_raw_grpc:
        # FIX 3 (2026-05-17): use raw gRPC for the etcd KV hot path.
        # Set the define, add the generated-stub include path, and
        # link grpc++/grpc/protobuf. The actual .pb.cc source files
        # are added to deptran_objects in the build() function below.
        conf.env.append_value("CXXFLAGS", "-DJANUS_ETCD_USE_RAW_GRPC=1")
        gen_proto_dir = os.path.abspath(
            'third_party/etcd-cpp-apiv3/build/proto/gen/proto')
        conf.env.append_value('INCLUDES', [gen_proto_dir])
        conf.env.append_value("LDFLAGS", ["-lgrpc++", "-lgrpc"])
        # protobuf is already linked via etcd-cpp-apiv3's deps; explicit
        # add in case ordering matters.
        conf.env.append_value("LDFLAGS", "-lprotobuf")
        conf.env.append_value("JANUS_ETCD_USE_RAW_GRPC", "1")

    # if Options.options.curp_fast_path:
    #     conf.env.append_value("CXXFLAGS", "-DCURP_FAST_PATH")
    # conf.env.append_value("CXXFLAGS", "-lprofiler scripts/pprof".split())
    conf.env.append_value("LDFLAGS", "-lprofiler")

    # enable mongodb
    # conf.env.append_value('CXXFLAGS', ['-std=c++17', '-ggdb'])
    # conf.env.append_value('INCLUDES', ['lib', 'include'])
    user_local = os.path.expanduser('~/local')
    conf.env.append_value('INCLUDES', [
        '/usr/local/include/mongocxx/v_noabi', '/usr/local/include/bsoncxx/v_noabi',
        user_local + '/include/mongocxx/v_noabi', user_local + '/include/bsoncxx/v_noabi',
        user_local + '/include',
    ])
    # conf.env.append_value("LINKFLAGS", ['-lboost_system', '-lpthread', '-lcrypto', '-lssl', '-lmongocxx', '-lbsoncxx'])
    # conf.env.append_value("LDFLAGS", ['-lboost_system', '-lpthread', '-lcrypto', '-lssl', '-lmongocxx', '-lbsoncxx'])
    conf.env.append_value('LIBPATH', [os.path.expanduser('~/.local/lib'), user_local + '/lib'])
    conf.env.append_value('RPATH', [os.path.expanduser('~/.local/lib'), user_local + '/lib'])
    conf.env.append_value("LDFLAGS", ["-lmongocxx", "-lbsoncxx"])
    conf.env.append_value("LDFLAGS", "-lcpprest")
    conf.env.append_value("LDFLAGS", "-letcd-cpp-api")

    # enable ZooKeeper synchronous API (zoo_exists, zoo_create, etc.)
    conf.env.append_value("CXXFLAGS", "-DTHREADED")
    conf.env.append_value("LDFLAGS", "-lzookeeper")
    conf.env.append_value("LDFLAGS", "-lhashtable")
    conf.env.append_value("LDFLAGS", ["-lssl", "-lcrypto"])

def build(bld):
    _depend("src/rrr/pylib/simplerpcgen/rpcgen.py",
            "src/rrr/pylib/simplerpcgen/rpcgen.g",
            "src/rrr/pylib/yapps/main.py src/rrr/pylib/simplerpcgen/rpcgen.g")

#    _depend("rlog/log_service.h", "rlog/log_service.rpc",
#            "bin/rpcgen rlog/log_service.rpc")

    _depend("src/deptran/rcc_rpc.h src/deptran/rcc_rpc.py",
            "src/deptran/rcc_rpc.rpc",
            "bin/rpcgen --python --cpp src/deptran/rcc_rpc.rpc")

    _gen_srpc_headers()

#     _depend("old-test/benchmark_service.h", "old-test/benchmark_service.rpc",
#             "bin/rpcgen --cpp old-test/benchmark_service.rpc")

    bld.stlib(source=bld.path.ant_glob("extern_interface/scheduler.c"),
              target="externc",
              includes="",
              use="")

    bld.stlib(source=bld.path.ant_glob("src/rrr/base/*.cpp "
                                       "src/rrr/misc/*.cpp "
                                       "src/rrr/rpc/*.cpp "
                                       "src/rrr/reactor/*.cc"),
              target="rrr",
              includes="src src/rrr",
              uselib="BOOST",
              use="PTHREAD")

#    bld.stlib(source=bld.path.ant_glob("rpc/*.cc"), target="simplerpc",
#              includes=". rrr rpc",
#              use="base PTHREAD")

    bld.stlib(source=bld.path.ant_glob("src/memdb/*.cc"), target="memdb",
              includes="src src/rrr src/deptran src/base",
              use="rrr PTHREAD")

    bld.shlib(features="pyext",
              source=bld.path.ant_glob("src/rrr/pylib/simplerpc/*.cpp"),
              target="_pyrpc",
              includes="src src/rrr src/rrr/rpc",
              uselib="BOOST",
              use="rrr simplerpc PYTHON")

    # FIX 3 source list: when raw-gRPC is enabled, also compile the
    # generated etcdserverpb stubs (KV-only subset, matching
    # scripts/build_backend_benches.sh).
    grpc_stub_sources = []
    if bld.env.JANUS_ETCD_USE_RAW_GRPC:
        gen_dir = "third_party/etcd-cpp-apiv3/build/proto/gen/proto"
        grpc_stub_sources = [
            gen_dir + "/rpc.pb.cc",
            gen_dir + "/rpc.grpc.pb.cc",
            gen_dir + "/kv.pb.cc",
            gen_dir + "/auth.pb.cc",
            gen_dir + "/gogoproto/gogo.pb.cc",
            gen_dir + "/google/api/annotations.pb.cc",
            gen_dir + "/google/api/http.pb.cc",
        ]

    bld.objects(source=bld.path.ant_glob("src/deptran/*.cc "
                                       "src/deptran/*/*.cc "
                                       "src/bench/*/*.cc",
                                       excl=['src/deptran/s_main.cc', 'src/deptran/paxos_main_helper.cc','src/deptran/lab_solution_raft/*.cc'])
                     + grpc_stub_sources,
              target="deptran_objects",
              includes="src src/rrr src/deptran ",
              uselib="YAML-CPP BOOST",
              use="externc rrr memdb PTHREAD PROFILER RT")

    bld.shlib(source=bld.path.ant_glob("src/deptran/paxos_main_helper.cc "),
              target="txlog",
              includes="src src/rrr src/deptran ",
              uselib="YAML-CPP BOOST",
              use="externc rrr memdb deptran_objects PTHREAD PROFILER RT")

    bld.program(source=bld.path.ant_glob("src/deptran/s_main.cc"),
              target="deptran_server",
              includes="src src/rrr src/deptran ",
              uselib="YAML-CPP BOOST",
              use="externc rrr memdb deptran_objects PTHREAD PROFILER RT")

    #bld.program(source=bld.path.ant_glob("src/run.cc "
    #                                     "src/deptran/paxos_main_helper.cc"),
    #            target="microbench",
    #            includes="src src/rrr src/deptran ",
    #            uselib="YAML-CPP BOOST",
    #            use="externc rrr memdb deptran_objects PTHREAD PROFILER RT")

    bld.add_post_fun(post)

def post(conf):
    _run_cmd("cp build/_pyrpc*.so src/rrr/pylib/simplerpc/")

#
# waf helper functions
#

def _enable_raft_test(conf):
    if Options.options.enable_raft_test:
        Logs.pprint("PINK", "Raft lab testing coroutine enabled")
        conf.env.append_value("CXXFLAGS", "-DRAFT_TEST_CORO")

def _choose_compiler(conf):
    # use clang++ as default compiler (for c++11 support on mac)
    if Options.options.cxx:
        os.environ["CXX"] = "g++"
    elif (sys.platform == 'darwin' and "CXX" not in os.environ) or Options.options.clang:
        os.environ["CXX"] = "clang++"
        conf.env.append_value("CXXFLAGS", "-stdlib=libc++")
        conf.env.append_value("LINKFLAGS", "-stdlib=libc++")
        Logs.pprint("PINK", "libc++ used")
    else:
        Logs.pprint("PINK", "use system default compiler")

def _enable_rpc_s(conf):
    if Options.options.rpc_s:
        conf.env.append_value("CXXFLAGS", "-DRPC_STATISTICS")
        Logs.pprint("PINK", "RPC statistics enabled")

def _enable_piece_count(conf):
    if Options.options.pc:
        conf.env.append_value("CXXFLAGS", "-DPIECE_COUNT")
        Logs.pprint("PINK", "Piece count enabled")

def _enable_txn_count(conf):
    if Options.options.txn_stat:
        conf.env.append_value("CXXFLAGS", "-DTXN_STAT")
        Logs.pprint("PINK", "Txn stat enabled")

def _enable_conflict_count(conf):
    if Options.options.cc:
        conf.env.append_value("CXXFLAGS", "-DCONFLICT_COUNT")
        Logs.pprint("PINK", "Conflict count enabled")

def _enable_logging(conf):
    #if Options.options.log:
    conf.check(compiler='cxx', lib='aio', mandatory=True, uselib_store="AIO")
    conf.env.append_value("CXXFLAGS", "-DRECORD")
    conf.env.append_value("LINKFLAGS", "-laio")
    Logs.pprint("PINK", "Logging enabled")

def _enable_reuse_coroutine(conf):
    if Options.options.disable_reuse_coroutine:
        Logs.pprint("RED", "Disable reuse coroutine, dangerous to performance!")
    else:
        conf.env.append_value("CXXFLAGS", "-DREUSE_CORO")
        Logs.pprint("PINK", "Reuse coroutine enabled")

def _enable_snappy(conf):
    Logs.pprint("PINK", "google snappy enabled")
    conf.env.append_value("LINKFLAGS", "-Wl,--no-as-needed")
    conf.env.append_value("LINKFLAGS", "-lsnappy")
    conf.env.append_value("LINKFLAGS", "-Wl,--as-needed")

def _enable_tcmalloc(conf):
    if Options.options.tcmalloc:
        Logs.pprint("PINK", "tcmalloc enabled")
        conf.env.append_value("LINKFLAGS", "-Wl,--no-as-needed")
        conf.env.append_value("LINKFLAGS", "-ltcmalloc")
        conf.env.append_value("LINKFLAGS", "-Wl,--as-needed")

def _enable_jemalloc(conf):
    if Options.options.jemalloc:
        Logs.pprint("PINK", "jemalloc enabled")
        conf.env.append_value("LINKFLAGS", "-Wl,--no-as-needed")
        conf.env.append_value("LINKFLAGS", "-ljemalloc")
        conf.env.append_value("LINKFLAGS", "-Wl,--as-needed")

def _enable_simulate_wan(conf):
    if Options.options.simulate_wan:
        Logs.pprint("PINK", "simulate wan")
        conf.env.append_value("CXXFLAGS", "-DSIMULATE_WAN")

def _enable_db_checksum(conf):
    if Options.options.db_checksum:
        Logs.pprint("PINK", "db checksum")
        conf.env.append_value("CXXFLAGS", "-DDB_CHECKSUM")

def _enable_leaksan(conf):
    if Options.options.leaksan:
        Logs.pprint("PINK", "leak sanitizer enabled")
        conf.env.append_value("CXXFLAGS", "-fsanitize=leak")

def _enable_pic(conf):
    conf.env.append_value("CXXFLAGS", "-fPIC")
    conf.env.append_value("LINKFLAGS", "-fPIC")

def _enable_cxx14(conf):
    Logs.pprint("PINK", "C++14 features enabled")
    if sys.platform == "darwin":
        conf.env.append_value("CXXFLAGS", "-stdlib=libc++")
        conf.env.append_value("LINKFLAGS", "-stdlib=libc++")
    conf.env.append_value("CXXFLAGS", "-std=c++14")

def _enable_profile(conf):
    if Options.options.prof:
        Logs.pprint("PINK", "CPU profiling enabled")
        conf.env.append_value("CXXFLAGS", "-DCPU_PROFILE")
        conf.env.LIB_PROFILER = 'profiler'

def _enable_event_timeout(conf):
    if Options.options.event_timeout:
        Logs.pprint("PINK", "event timeout enabled")
        conf.env.append_value("CXXFLAGS", "-DEVENT_TIMEOUT_CHECK")

def _enable_ipc(conf):
    if Options.options.ipc:
        Logs.pprint("PINK", "Use IPC instead of network socket")
        conf.env.append_value("CXXFLAGS", "-DUSE_IPC")

def _enable_debug(conf):
    if Options.options.debug:
        Logs.pprint("PINK", "Debug support enabled")
        conf.env.append_value("CXXFLAGS", "-Wall -pthread -O0 -DNDEBUG -g "
                "-ggdb -DLOG_LEVEL_AS_DEBUG -DLOG_DEBUG -rdynamic -fno-omit-frame-pointer".split())
    else:
        if Options.options.mutrace:
            Logs.pprint("PINK", "mutrace debugging enabled")
            conf.env.append_value("CXXFLAGS", "-Wall -pthread -O0 -DNDEBUG -g "
                "-ggdb -DLOG_INFO -rdynamic -fno-omit-frame-pointer".split())
        else:
            conf.env.append_value("CXXFLAGS", "-g -pthread -O2 -DNDEBUG -DLOG_INFO".split())
            # conf.env.append_value("CXXFLAGS", "-g -pthread -O0 -DNDEBUG -DLOG_INFO".split())

def _properly_split(args):
    if args == None:
        return []
    else:
        return args.split()

def _gen_srpc_headers():
    for srpc in glob.glob("deptran/*/*.rpc"):
        target = os.path.splitext(srpc)[0]+'.h'
        _depend(target,
                srpc,
                "bin/rpcgen --cpp " + srpc)
    pass

def _depend(target, source, action):
    target = _properly_split(target)
    source = _properly_split(source)
    for s in source:
        if not os.path.exists(s):
            Logs.pprint('RED', "'%s' not found!" % s)
            exit(1)
    for t in target:
        if not os.path.exists(t):
            _run_cmd(action)
    if not target or min([os.stat(t).st_mtime for t in target]) < max([os.stat(s).st_mtime for s in source]):
        _run_cmd(action)

def _run_cmd(cmd):
    Logs.pprint('PINK', cmd)
    os.system(cmd)
