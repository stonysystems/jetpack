#include "deptran/__dep__.h"
#include "procedure.h"

namespace janus {

void TpccProcedure::DeliveryInit(TxRequest &req) {
  // Pieces 0-3 merged into single piece 0 (all W_ID-sharded)
  n_pieces_all_ = 1;

  output_size_[TPCC_DELIVERY_0] = 0;

  p_types_[TPCC_DELIVERY_0] = TPCC_DELIVERY_0;

  status_[TPCC_DELIVERY_0] = WAITING;
  CheckReady();
}

void TpccProcedure::DeliveryRetry() {
  status_[TPCC_DELIVERY_0] = WAITING;
  CheckReady();
}


void TpccWorkload::RegDelivery() {
  // All 4 delivery pieces merged into piece 0 (all W_ID-sharded).
  // Pieces 1-3 were: order R/W, order_line R/W, customer W.
  RegP(TPCC_DELIVERY, TPCC_DELIVERY_0,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_O_CARRIER_ID}, // i
       {},  // o
       {conf_id_t(TPCC_TB_NEW_ORDER,
               {TPCC_VAR_D_ID, TPCC_VAR_W_ID},
               {TPCC_COL_NEW_ORDER_NO_O_ID},
               RS_NEW_ORDER),
        conf_id_t(TPCC_TB_ORDER,
               {TPCC_VAR_D_ID, TPCC_VAR_W_ID},
               {TPCC_COL_ORDER_O_CARRIER_ID},
               ROW_ORDER),
        conf_id_t(TPCC_TB_ORDER_LINE,
               {TPCC_VAR_D_ID, TPCC_VAR_W_ID},
               {TPCC_COL_ORDER_LINE_OL_AMOUNT,
                TPCC_COL_ORDER_LINE_OL_DELIVERY_D},
               RS_ORDER_LINE),
        conf_id_t(TPCC_TB_CUSTOMER,
               {TPCC_VAR_D_ID, TPCC_VAR_W_ID},
               {TPCC_COL_CUSTOMER_C_BALANCE,
                TPCC_COL_CUSTOMER_C_DELIVERY_CNT},
               ROW_CUSTOMER)}, // c
       {TPCC_TB_NEW_ORDER, {TPCC_VAR_W_ID}}, // s
       DF_REAL,
       PROC {
         // --- former piece 0: Ri & W new_order ---
         Log_debug("TPCC_DELIVERY, piece: %d", TPCC_DELIVERY_0);
         verify(cmd.input.size() >= 3);
         Value buf;
         mdb::Row *r = NULL;
         mdb::Table *tbl = tx.GetTable(TPCC_TB_NEW_ORDER);

         mdb::MultiBlob mbl(3), mbh(3);
         mbl[0] = cmd.input[TPCC_VAR_D_ID].get_blob();
         mbh[0] = cmd.input[TPCC_VAR_D_ID].get_blob();
         mbl[1] = cmd.input[TPCC_VAR_W_ID].get_blob();
         mbh[1] = cmd.input[TPCC_VAR_W_ID].get_blob();
         Value no_o_id_low(std::numeric_limits<i32>::min()),
             no_o_id_high(std::numeric_limits<i32>::max());
         mbl[2] = no_o_id_low.get_blob();
         mbh[2] = no_o_id_high.get_blob();

         mdb::ResultSet rs = tx.QueryIn(tbl,
                                           mbl,
                                           mbh,
                                           mdb::ORD_ASC,
                                           RS_NEW_ORDER);
         Value o_id(0);
         if (rs.has_next()) {
           r = rs.next();
           tx.ReadColumn(r, TPCC_COL_NEW_ORDER_NO_W_ID, &o_id, TXN_DEFERRED);
         } else {
           *res = SUCCESS;
           return;
         }

         // --- former piece 1: Ri & W order ---
         mdb::Txn *txn = tx.mdb_txn_;
         mdb::MultiBlob mb(3);
         mb[0] = cmd.input[TPCC_VAR_D_ID].get_blob();
         mb[1] = cmd.input[TPCC_VAR_W_ID].get_blob();
         mb[2] = o_id.get_blob();
         auto tbl_order = txn->get_table(TPCC_TB_ORDER);
         mdb::Row *row_order = tx.Query(tbl_order, mb, ROW_ORDER);
         Value c_id_val;
         tx.ReadColumn(row_order,
                          TPCC_COL_ORDER_O_C_ID,
                          &c_id_val,
                          TXN_BYPASS);
         tx.WriteColumn(row_order,
                           TPCC_COL_ORDER_O_CARRIER_ID,
                           cmd.input[TPCC_VAR_O_CARRIER_ID],
                           TXN_DEFERRED);

         // --- former piece 2: Ri & W order_line ---
         mdb::MultiBlob mbl_ol(4), mbh_ol(4);
         mbl_ol[0] = cmd.input[TPCC_VAR_D_ID].get_blob();
         mbh_ol[0] = cmd.input[TPCC_VAR_D_ID].get_blob();
         mbl_ol[1] = cmd.input[TPCC_VAR_W_ID].get_blob();
         mbh_ol[1] = cmd.input[TPCC_VAR_W_ID].get_blob();
         mbl_ol[2] = o_id.get_blob();
         mbh_ol[2] = o_id.get_blob();
         Value ol_number_low(std::numeric_limits<i32>::min()),
             ol_number_high(std::numeric_limits<i32>::max());
         mbl_ol[3] = ol_number_low.get_blob();
         mbh_ol[3] = ol_number_high.get_blob();

         mdb::ResultSet
             rs_ol = tx.QueryIn(tx.GetTable(TPCC_TB_ORDER_LINE),
                                   mbl_ol,
                                   mbh_ol,
                                   mdb::ORD_ASC,
                                   RS_ORDER_LINE);
         mdb::Row *row_ol = nullptr;

         std::vector<mdb::Row *> row_list;
         row_list.reserve(15);
         while (rs_ol.has_next()) {
           row_list.push_back(rs_ol.next());
         }

         int i = 0;
         double ol_amount_buf = 0.0;

         while (i < row_list.size()) {
           row_ol = row_list[i++];
           Value ol_buf(0.0);
           tx.ReadColumn(row_ol, TPCC_COL_ORDER_LINE_OL_AMOUNT,
                            &ol_buf, TXN_DEFERRED);
           ol_amount_buf += ol_buf.get_double();
           tx.WriteColumn(row_ol, TPCC_COL_ORDER_LINE_OL_DELIVERY_D,
                             Value(std::to_string(time(NULL))),
                             TXN_DEFERRED);
         }

         // --- former piece 3: W customer ---
         mdb::Row *row_customer = NULL;
         mdb::MultiBlob mb_cust(3);
         mb_cust[0] = c_id_val.get_blob();
         mb_cust[1] = cmd.input[TPCC_VAR_D_ID].get_blob();
         mb_cust[2] = cmd.input[TPCC_VAR_W_ID].get_blob();

         auto tbl_customer = tx.GetTable(TPCC_TB_CUSTOMER);
         row_customer = tx.Query(tbl_customer, mb_cust, ROW_CUSTOMER);
         Value cust_buf = Value(0.0);
         tx.ReadColumn(row_customer, TPCC_COL_CUSTOMER_C_BALANCE,
                          &cust_buf, TXN_DEFERRED);
         cust_buf.set_double(cust_buf.get_double() + ol_amount_buf);
         tx.WriteColumn(row_customer, TPCC_COL_CUSTOMER_C_BALANCE,
                           cust_buf, TXN_DEFERRED);
         tx.ReadColumn(row_customer, TPCC_COL_CUSTOMER_C_DELIVERY_CNT,
                          &cust_buf, TXN_BYPASS);
         cust_buf.set_i32(cust_buf.get_i32() + (i32) 1);
         tx.WriteColumn(row_customer, TPCC_COL_CUSTOMER_C_DELIVERY_CNT,
                           cust_buf, TXN_DEFERRED);
         *res = SUCCESS;
         return;
       }
  );
}

} // namespace janus
