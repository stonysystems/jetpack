//! `Init` establishes `inv` (not trusted).
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use crate::proof::defs::*;
use vstd::prelude::*;

verus! {

pub proof fn lemma_init_inv(cfg: Config, s: SystemState)
    requires
        wf(cfg),
        Init(cfg, s),
    ensures
        inv(cfg, s),
{
    assert forall|r: int| #[trigger] cfg.replicas.contains(r) implies {
        &&& replica_wf(cfg, s, r)
        &&& coord_ok(cfg, s, r)
        &&& accepted_ok(cfg, s, r)
        &&& acks_ok(cfg, s, r)
        &&& poks_ok(cfg, s, r)
    } by {
        assert(s.replicas[r] == replica_init());
        assert(s.replicas[r].coord.phase is Idle);
        assert(s.replicas[r].accepted.dom() == Set::<int>::empty());
    }
    assert forall|k: int| #[trigger] cfg.clients.contains(k) implies client_ok(cfg, s, k) by {
        assert(s.clients[k] == client_init());
    }
}

} // verus!
