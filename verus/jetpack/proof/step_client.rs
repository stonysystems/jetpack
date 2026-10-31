//! §1 normal path, client side (not trusted): N1/N10, N2-N5, N8-N9 preserve `inv`.
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use crate::proof::defs::*;
use crate::proof::frame::*;
use crate::proof::keep::*;
use crate::proof::mono::*;
use vstd::prelude::*;

verus! {

pub proof fn lemma_client_step_inv(cfg: Config, s: SystemState, s_: SystemState, k: int, step: ClientStep, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ClientNodeStep(cfg, s, s_, k, step, sent),
    ensures
        inv(cfg, s_),
{
    lemma_client_step_frame(cfg, s, s_, k, step, sent);
    let c = client_consts(cfg, k);
    let st = s.clients[k];
    let st_ = s_.clients[k];
    assert(client_ok(cfg, s, k));
    lemma_wf_proposer(cfg, v0());
    let r0 = (cfg.proposer)(v0());
    // the new packets and the stepping client
    match step {
        ClientStep::SendFastCmd { cmd } => {
            assert(ClientSendFastCmd(c, st, st_, cmd, sent));
            let msg = Msg::FastCmd { view: st.view, cmd: cmd };
            assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
                implies msg_ok(cfg, s_, p) && p.src is Client by {
                assert(sent.contains(p));
                lemma_to_replicas_contains(cfg.replicas, client_addr(c), msg, p);
            }
            assert(st_ == st);
            assert(client_ok(cfg, s_, k)) by {
                assert forall|fc: FastCommit| #[trigger] st_.fast.contains(fc) implies fast_committed(cfg, s_, fc.view, fc.cmd) by {
                    lemma_fast_committed_mono(cfg, s, s_, fc.view, fc.cmd);
                }
            }
        },
        ClientStep::FastCommit { pkts, q, cmd } => {
            assert(ClientFastCommit(c, st, st_, pkts, q, cmd, sent));
            assert(sent == Set::<Packet>::empty());
            assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
                implies msg_ok(cfg, s_, p) && p.src is Client by {
                assert(sent.contains(p));
            }
            let fc0 = FastCommit { view: st.view, cmd: cmd };
            assert(st_ == ClientState { fast: st.fast.insert(fc0), ..st });
            // the decided fast commit is one: q is a superquorum with every proposer that ack'd c in K.view
            assert(c_sq(c) == sq(cfg));
            assert forall|r: int| #[trigger] q.contains(r) implies acked(s_, r, st.view, cmd) by {
                let p = Packet { src: Addr::Replica { id: r }, dst: client_addr(c), msg: Msg::FastAck { view: st.view, cmd: cmd } };
                assert(pkts.contains(p));
                assert(client_received(step).contains(p));
                assert(s.network.contains(p));
                assert(s_.network.contains(p));
            }
            assert(q.subset_of(cfg.replicas));
            assert(fast_committed(cfg, s_, st.view, cmd));
            assert(client_ok(cfg, s_, k)) by {
                assert forall|fc: FastCommit| #[trigger] st_.fast.contains(fc) implies fast_committed(cfg, s_, fc.view, fc.cmd) by {
                    if fc == fc0 {
                    } else {
                        assert(st.fast.contains(fc));
                        lemma_fast_committed_mono(cfg, s, s_, fc.view, fc.cmd);
                    }
                }
            }
        },
        ClientStep::RecvFastNack { pkt } => {
            assert(ClientRecvFastNack(c, st, st_, pkt, sent));
            assert(client_received(step).contains(pkt));
            assert(s.network.contains(pkt));
            assert(msg_ok(cfg, s, pkt));
            assert(sent == Set::<Packet>::empty());
            assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
                implies msg_ok(cfg, s_, p) && p.src is Client by {
                assert(sent.contains(p));
            }
            assert(client_ok(cfg, s_, k)) by {
                assert forall|fc: FastCommit| #[trigger] st_.fast.contains(fc) implies fast_committed(cfg, s_, fc.view, fc.cmd) by {
                    assert(st.fast.contains(fc));
                    lemma_fast_committed_mono(cfg, s, s_, fc.view, fc.cmd);
                }
            }
        },
    }
    // the other clients
    assert forall|k2: int| #[trigger] cfg.clients.contains(k2) implies client_ok(cfg, s_, k2) by {
        if k2 != k {
            assert(s_.clients[k2] == s.clients[k2]);
            assert(client_ok(cfg, s, k2));
            assert forall|fc: FastCommit| #[trigger] s_.clients[k2].fast.contains(fc) implies fast_committed(cfg, s_, fc.view, fc.cmd) by {
                lemma_fast_committed_mono(cfg, s, s_, fc.view, fc.cmd);
            }
        }
    }
    // the replicas did not move
    lemma_preds_unchanged(cfg, s, s_, r0);
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_inv_assemble(cfg, s, s_, r0);
}

} // verus!
