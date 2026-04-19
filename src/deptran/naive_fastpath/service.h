#pragma once

// Pulled includes to match other protocols' service.h so that the generated
// rcc_rpc.h sees all its transitive dependencies (parent_set_t, SimpleCommand,
// MarshallDeputy, graph/graph_marshaler) before the rpc handler signatures
// are declared.
#include "../__dep__.h"
#include "../constants.h"
#include "../rcc/graph.h"
#include "../rcc/graph_marshaler.h"
#include "../command.h"
#include "../procedure.h"
#include "../command_marshaler.h"
#include "../rcc_rpc.h"
#include "../service.h"
