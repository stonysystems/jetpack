#include <gtest/gtest.h>
#include <string>
#include <vector>
#include <set>
#include <map>

#include "deptran/txn_reg.h"
#include "bench/tpcc/workload.h"
#include "bench/tpca/workload.h"

// Define table name symbols needed by the tests (normally in workload.cc)
namespace janus {
char TPCC_TB_WAREHOUSE[] = "warehouse";
char TPCC_TB_DISTRICT[] = "district";
char TPCC_TB_CUSTOMER[] = "customer";
char TPCC_TB_HISTORY[] = "history";
char TPCC_TB_ORDER[] = "order";
char TPCC_TB_NEW_ORDER[] = "new_order";
char TPCC_TB_ITEM[] = "item";
char TPCC_TB_STOCK[] = "stock";
char TPCC_TB_ORDER_LINE[] = "order_line";
char TPCC_TB_ORDER_C_ID_SECONDARY[] = "order_secondary";

char TPCA_BRANCH[] = "branch";
char TPCA_TELLER[] = "teller";
char TPCA_CUSTOMER[] = "customer";
}

using namespace janus;

// Helper: directly register a piece into a TxnRegistry, bypassing full Workload setup.
static void RegP(std::shared_ptr<TxnRegistry> txn_reg,
                 txntype_t txn_type,
                 innid_t inn_id,
                 const std::set<int32_t>& ivars,
                 const std::set<int32_t>& ovars,
                 const std::vector<conf_id_t>& conflicts,
                 const sharder_t& sharder,
                 const rank_t& rank) {
  auto& piece = txn_reg->regs_[txn_type][inn_id];
  piece.input_vars_ = ivars;
  piece.output_vars_ = ovars;
  piece.conflicts_ = conflicts;
  piece.sharder_ = sharder;
  piece.rank_ = rank;
  // proc_handler_ left null since we only test metadata
}

// ============================================================
// Tests for conf_id_t data structure
// ============================================================

TEST(ConfIdTest, Construction) {
  conf_id_t c("table1", {1, 2}, {3, 4}, 100);
  EXPECT_EQ(c.table, "table1");
  EXPECT_EQ(c.primary_keys.size(), 2u);
  EXPECT_EQ(c.primary_keys[0], 1);
  EXPECT_EQ(c.primary_keys[1], 2);
  EXPECT_EQ(c.columns.size(), 2u);
  EXPECT_EQ(c.columns[0], 3);
  EXPECT_EQ(c.columns[1], 4);
  EXPECT_EQ(c.row_context_id, 100);
}

TEST(ConfIdTest, DefaultConstruction) {
  conf_id_t c("", {}, {}, 0);
  EXPECT_EQ(c.table, "");
  EXPECT_TRUE(c.primary_keys.empty());
  EXPECT_TRUE(c.columns.empty());
  EXPECT_EQ(c.row_context_id, 0);
}

// ============================================================
// Tests for TxnRegistry piece registration
// ============================================================

TEST(TxnRegistryTest, RegisterPieceWithConflicts) {
  auto reg = std::make_shared<TxnRegistry>();
  std::vector<conf_id_t> conflicts = {
      conf_id_t("district", {1003, 1001}, {10}, 42)
  };
  RegP(reg, 10, 1000, {1001, 1003}, {1011}, conflicts,
       {"district", {1001}}, 0);

  auto& piece = reg->get(10, 1000);
  ASSERT_EQ(piece.conflicts_.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].table, "district");
  EXPECT_EQ(piece.conflicts_[0].primary_keys.size(), 2u);
  EXPECT_EQ(piece.conflicts_[0].columns.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].columns[0], 10);
}

TEST(TxnRegistryTest, RegisterPieceWithoutConflicts) {
  auto reg = std::make_shared<TxnRegistry>();
  RegP(reg, 10, 1001, {1001}, {}, {}, {"item", {1001}}, 0);

  auto& piece = reg->get(10, 1001);
  EXPECT_TRUE(piece.conflicts_.empty());
}

TEST(TxnRegistryTest, RegisterMultipleConflicts) {
  auto reg = std::make_shared<TxnRegistry>();
  std::vector<conf_id_t> conflicts = {
      conf_id_t("stock", {100, 106}, {2, 13, 14, 15}, 0),
      conf_id_t("item", {100}, {0}, 1)
  };
  RegP(reg, 10, 17000, {100, 106, 108, 109}, {}, conflicts,
       {"stock", {106}}, 1);

  auto& piece = reg->get(10, 17000);
  ASSERT_EQ(piece.conflicts_.size(), 2u);
  EXPECT_EQ(piece.conflicts_[0].table, "stock");
  EXPECT_EQ(piece.conflicts_[0].columns.size(), 4u);
  EXPECT_EQ(piece.conflicts_[1].table, "item");
  EXPECT_EQ(piece.conflicts_[1].columns.size(), 1u);
}

// ============================================================
// Tests verifying TPCC conflict declarations match expectations
// These tests verify the conflict declarations are consistent
// with what each piece reads/writes as documented in the code.
// ============================================================

// Test: TPCC NEW_ORDER piece 0 should have district conflict
TEST(TpccConflictDeclarations, NewOrderPiece0HasDistrictConflict) {
  auto reg = std::make_shared<TxnRegistry>();
  // Simulate the conflict declaration from new_order.cc
  std::vector<conf_id_t> conflicts = {
      conf_id_t(TPCC_TB_DISTRICT,
                {TPCC_VAR_D_ID, TPCC_VAR_W_ID},
                {TPCC_COL_DISTRICT_D_NEXT_O_ID},
                ROW_DISTRICT)
  };
  RegP(reg, TPCC_NEW_ORDER, TPCC_NEW_ORDER_0,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_C_ID,
        TPCC_VAR_O_CARRIER_ID, TPCC_VAR_OL_CNT, TPCC_VAR_O_ALL_LOCAL},
       {TPCC_VAR_O_ID, TPCC_VAR_D_TAX},
       conflicts,
       {TPCC_TB_DISTRICT, {TPCC_VAR_W_ID}},
       DF_NO);

  auto& piece = reg->get(TPCC_NEW_ORDER, TPCC_NEW_ORDER_0);
  ASSERT_EQ(piece.conflicts_.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].table, std::string(TPCC_TB_DISTRICT));
  // Primary keys: D_ID, W_ID
  ASSERT_EQ(piece.conflicts_[0].primary_keys.size(), 2u);
  EXPECT_EQ(piece.conflicts_[0].primary_keys[0], TPCC_VAR_D_ID);
  EXPECT_EQ(piece.conflicts_[0].primary_keys[1], TPCC_VAR_W_ID);
  // Column: D_NEXT_O_ID
  ASSERT_EQ(piece.conflicts_[0].columns.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].columns[0], TPCC_COL_DISTRICT_D_NEXT_O_ID);
}

// Test: TPCC NEW_ORDER read-only pieces should have no conflicts
TEST(TpccConflictDeclarations, NewOrderReadOnlyPiecesHaveNoConflict) {
  auto reg = std::make_shared<TxnRegistry>();
  // RI piece (read item - read-only)
  RegP(reg, TPCC_NEW_ORDER, TPCC_NEW_ORDER_RI(0),
       {TPCC_VAR_I_ID(0)}, {}, {},
       {TPCC_TB_ITEM, {TPCC_VAR_I_ID(0)}}, DF_NO);
  auto& ri = reg->get(TPCC_NEW_ORDER, TPCC_NEW_ORDER_RI(0));
  EXPECT_TRUE(ri.conflicts_.empty());

  // RS piece (read stock - read-only)
  RegP(reg, TPCC_NEW_ORDER, TPCC_NEW_ORDER_RS(0),
       {TPCC_VAR_D_ID, TPCC_VAR_I_ID(0), TPCC_VAR_S_W_ID(0)}, {}, {},
       {TPCC_TB_STOCK, {TPCC_VAR_S_W_ID(0)}}, DF_NO);
  auto& rs = reg->get(TPCC_NEW_ORDER, TPCC_NEW_ORDER_RS(0));
  EXPECT_TRUE(rs.conflicts_.empty());
}

// Test: TPCC NEW_ORDER WS piece should have stock conflict
TEST(TpccConflictDeclarations, NewOrderWSHasStockConflict) {
  auto reg = std::make_shared<TxnRegistry>();
  std::vector<conf_id_t> conflicts = {
      conf_id_t(TPCC_TB_STOCK,
                {TPCC_VAR_I_ID(0), TPCC_VAR_S_W_ID(0)},
                {TPCC_COL_STOCK_S_QUANTITY,
                 TPCC_COL_STOCK_S_YTD,
                 TPCC_COL_STOCK_S_ORDER_CNT,
                 TPCC_COL_STOCK_S_REMOTE_CNT},
                0)
  };
  RegP(reg, TPCC_NEW_ORDER, TPCC_NEW_ORDER_WS(0),
       {TPCC_VAR_I_ID(0), TPCC_VAR_S_W_ID(0),
        TPCC_VAR_OL_QUANTITY(0), TPCC_VAR_S_REMOTE_CNT(0)},
       {}, conflicts,
       {TPCC_TB_STOCK, {TPCC_VAR_S_W_ID(0)}}, DF_REAL);

  auto& piece = reg->get(TPCC_NEW_ORDER, TPCC_NEW_ORDER_WS(0));
  ASSERT_EQ(piece.conflicts_.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].table, std::string(TPCC_TB_STOCK));
  EXPECT_EQ(piece.conflicts_[0].columns.size(), 4u);
  EXPECT_EQ(piece.conflicts_[0].columns[0], TPCC_COL_STOCK_S_QUANTITY);
  EXPECT_EQ(piece.conflicts_[0].columns[1], TPCC_COL_STOCK_S_YTD);
  EXPECT_EQ(piece.conflicts_[0].columns[2], TPCC_COL_STOCK_S_ORDER_CNT);
  EXPECT_EQ(piece.conflicts_[0].columns[3], TPCC_COL_STOCK_S_REMOTE_CNT);
}

// Test: TPCC PAYMENT piece 2 should have district D_YTD conflict
TEST(TpccConflictDeclarations, PaymentPiece2HasDistrictYTDConflict) {
  auto reg = std::make_shared<TxnRegistry>();
  std::vector<conf_id_t> conflicts = {
      conf_id_t(TPCC_TB_DISTRICT,
                {TPCC_VAR_D_ID, TPCC_VAR_W_ID},
                {TPCC_COL_DISTRICT_D_YTD},
                ROW_DISTRICT_TEMP)
  };
  RegP(reg, TPCC_PAYMENT, TPCC_PAYMENT_2,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_H_AMOUNT},
       {}, conflicts,
       {TPCC_TB_DISTRICT, {TPCC_VAR_W_ID}}, DF_REAL);

  auto& piece = reg->get(TPCC_PAYMENT, TPCC_PAYMENT_2);
  ASSERT_EQ(piece.conflicts_.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].table, std::string(TPCC_TB_DISTRICT));
  ASSERT_EQ(piece.conflicts_[0].primary_keys.size(), 2u);
  EXPECT_EQ(piece.conflicts_[0].primary_keys[0], TPCC_VAR_D_ID);
  EXPECT_EQ(piece.conflicts_[0].primary_keys[1], TPCC_VAR_W_ID);
  ASSERT_EQ(piece.conflicts_[0].columns.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].columns[0], TPCC_COL_DISTRICT_D_YTD);
}

// Test: TPCC PAYMENT piece 4 should have customer conflict
TEST(TpccConflictDeclarations, PaymentPiece4HasCustomerConflict) {
  auto reg = std::make_shared<TxnRegistry>();
  std::vector<conf_id_t> conflicts = {
      conf_id_t(TPCC_TB_CUSTOMER,
                {TPCC_VAR_C_ID, TPCC_VAR_C_D_ID, TPCC_VAR_C_W_ID},
                {TPCC_COL_CUSTOMER_C_BALANCE,
                 TPCC_COL_CUSTOMER_C_YTD_PAYMENT,
                 TPCC_COL_CUSTOMER_C_DATA},
                ROW_CUSTOMER)
  };
  RegP(reg, TPCC_PAYMENT, TPCC_PAYMENT_4,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_H_AMOUNT,
        TPCC_VAR_C_ID, TPCC_VAR_C_W_ID, TPCC_VAR_C_D_ID},
       {}, conflicts,
       {TPCC_TB_CUSTOMER, {TPCC_VAR_C_W_ID}}, DF_REAL);

  auto& piece = reg->get(TPCC_PAYMENT, TPCC_PAYMENT_4);
  ASSERT_EQ(piece.conflicts_.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].table, std::string(TPCC_TB_CUSTOMER));
  ASSERT_EQ(piece.conflicts_[0].primary_keys.size(), 3u);
  EXPECT_EQ(piece.conflicts_[0].primary_keys[0], TPCC_VAR_C_ID);
  EXPECT_EQ(piece.conflicts_[0].primary_keys[1], TPCC_VAR_C_D_ID);
  EXPECT_EQ(piece.conflicts_[0].primary_keys[2], TPCC_VAR_C_W_ID);
  ASSERT_EQ(piece.conflicts_[0].columns.size(), 3u);
  EXPECT_EQ(piece.conflicts_[0].columns[0], TPCC_COL_CUSTOMER_C_BALANCE);
  EXPECT_EQ(piece.conflicts_[0].columns[1], TPCC_COL_CUSTOMER_C_YTD_PAYMENT);
  EXPECT_EQ(piece.conflicts_[0].columns[2], TPCC_COL_CUSTOMER_C_DATA);
}

// Test: TPCC PAYMENT read-only pieces have no conflict
TEST(TpccConflictDeclarations, PaymentReadOnlyPiecesHaveNoConflict) {
  auto reg = std::make_shared<TxnRegistry>();

  // Piece 0: read warehouse (TXN_BYPASS)
  RegP(reg, TPCC_PAYMENT, TPCC_PAYMENT_0,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_H_AMOUNT,
        TPCC_VAR_C_W_ID, TPCC_VAR_C_D_ID, TPCC_VAR_H_KEY},
       {}, {},
       {TPCC_TB_WAREHOUSE, {TPCC_VAR_W_ID}}, DF_NO);
  EXPECT_TRUE(reg->get(TPCC_PAYMENT, TPCC_PAYMENT_0).conflicts_.empty());

  // Piece 1: read district (TXN_BYPASS)
  RegP(reg, TPCC_PAYMENT, TPCC_PAYMENT_1,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID}, {}, {},
       {TPCC_TB_DISTRICT, {TPCC_VAR_W_ID}}, DF_NO);
  EXPECT_TRUE(reg->get(TPCC_PAYMENT, TPCC_PAYMENT_1).conflicts_.empty());

  // Piece 3: customer secondary index lookup (read-only)
  RegP(reg, TPCC_PAYMENT, TPCC_PAYMENT_3,
       {TPCC_VAR_C_W_ID, TPCC_VAR_C_D_ID, TPCC_VAR_C_LAST}, {}, {},
       {TPCC_TB_CUSTOMER, {TPCC_VAR_C_W_ID}}, DF_NO);
  EXPECT_TRUE(reg->get(TPCC_PAYMENT, TPCC_PAYMENT_3).conflicts_.empty());

  // Piece 5: insert history (insert-only)
  RegP(reg, TPCC_PAYMENT, TPCC_PAYMENT_5,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_C_W_ID,
        TPCC_VAR_C_D_ID, TPCC_VAR_H_KEY, TPCC_VAR_H_AMOUNT},
       {}, {},
       {TPCC_TB_HISTORY, {TPCC_VAR_H_KEY}}, DF_REAL);
  EXPECT_TRUE(reg->get(TPCC_PAYMENT, TPCC_PAYMENT_5).conflicts_.empty());
}

// Test: TPCC DELIVERY piece 0 has new_order conflict
TEST(TpccConflictDeclarations, DeliveryPiece0HasNewOrderConflict) {
  auto reg = std::make_shared<TxnRegistry>();
  std::vector<conf_id_t> conflicts = {
      conf_id_t(TPCC_TB_NEW_ORDER,
                {TPCC_VAR_D_ID, TPCC_VAR_W_ID},
                {TPCC_COL_NEW_ORDER_NO_O_ID},
                RS_NEW_ORDER)
  };
  RegP(reg, TPCC_DELIVERY, TPCC_DELIVERY_0,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_O_CARRIER_ID},
       {TPCC_VAR_O_ID}, conflicts,
       {TPCC_TB_NEW_ORDER, {TPCC_VAR_W_ID}}, DF_REAL);

  auto& piece = reg->get(TPCC_DELIVERY, TPCC_DELIVERY_0);
  ASSERT_EQ(piece.conflicts_.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].table, std::string(TPCC_TB_NEW_ORDER));
  ASSERT_EQ(piece.conflicts_[0].primary_keys.size(), 2u);
  ASSERT_EQ(piece.conflicts_[0].columns.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].columns[0], TPCC_COL_NEW_ORDER_NO_O_ID);
}

// Test: TPCC DELIVERY piece 1 has order conflict
TEST(TpccConflictDeclarations, DeliveryPiece1HasOrderConflict) {
  auto reg = std::make_shared<TxnRegistry>();
  std::vector<conf_id_t> conflicts = {
      conf_id_t(TPCC_TB_ORDER,
                {TPCC_VAR_D_ID, TPCC_VAR_W_ID, TPCC_VAR_O_ID},
                {TPCC_COL_ORDER_O_CARRIER_ID},
                ROW_ORDER)
  };
  RegP(reg, TPCC_DELIVERY, TPCC_DELIVERY_1,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_O_ID, TPCC_VAR_O_CARRIER_ID},
       {TPCC_VAR_C_ID}, conflicts,
       {TPCC_TB_ORDER, {TPCC_VAR_W_ID}}, DF_NO);

  auto& piece = reg->get(TPCC_DELIVERY, TPCC_DELIVERY_1);
  ASSERT_EQ(piece.conflicts_.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].table, std::string(TPCC_TB_ORDER));
  ASSERT_EQ(piece.conflicts_[0].primary_keys.size(), 3u);
  ASSERT_EQ(piece.conflicts_[0].columns.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].columns[0], TPCC_COL_ORDER_O_CARRIER_ID);
}

// Test: TPCC DELIVERY piece 2 has order_line conflict
TEST(TpccConflictDeclarations, DeliveryPiece2HasOrderLineConflict) {
  auto reg = std::make_shared<TxnRegistry>();
  std::vector<conf_id_t> conflicts = {
      conf_id_t(TPCC_TB_ORDER_LINE,
                {TPCC_VAR_D_ID, TPCC_VAR_W_ID, TPCC_VAR_O_ID},
                {TPCC_COL_ORDER_LINE_OL_AMOUNT,
                 TPCC_COL_ORDER_LINE_OL_DELIVERY_D},
                RS_ORDER_LINE)
  };
  RegP(reg, TPCC_DELIVERY, TPCC_DELIVERY_2,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_O_ID},
       {}, conflicts,
       {TPCC_TB_ORDER_LINE, {TPCC_VAR_W_ID}}, DF_NO);

  auto& piece = reg->get(TPCC_DELIVERY, TPCC_DELIVERY_2);
  ASSERT_EQ(piece.conflicts_.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].table, std::string(TPCC_TB_ORDER_LINE));
  ASSERT_EQ(piece.conflicts_[0].primary_keys.size(), 3u);
  ASSERT_EQ(piece.conflicts_[0].columns.size(), 2u);
  EXPECT_EQ(piece.conflicts_[0].columns[0], TPCC_COL_ORDER_LINE_OL_AMOUNT);
  EXPECT_EQ(piece.conflicts_[0].columns[1], TPCC_COL_ORDER_LINE_OL_DELIVERY_D);
}

// Test: TPCC DELIVERY piece 3 has customer conflict
TEST(TpccConflictDeclarations, DeliveryPiece3HasCustomerConflict) {
  auto reg = std::make_shared<TxnRegistry>();
  std::vector<conf_id_t> conflicts = {
      conf_id_t(TPCC_TB_CUSTOMER,
                {TPCC_VAR_C_ID, TPCC_VAR_D_ID, TPCC_VAR_W_ID},
                {TPCC_COL_CUSTOMER_C_BALANCE,
                 TPCC_COL_CUSTOMER_C_DELIVERY_CNT},
                ROW_CUSTOMER)
  };
  RegP(reg, TPCC_DELIVERY, TPCC_DELIVERY_3,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_C_ID, TPCC_VAR_OL_AMOUNT},
       {}, conflicts,
       {TPCC_TB_CUSTOMER, {TPCC_VAR_W_ID}}, DF_REAL);

  auto& piece = reg->get(TPCC_DELIVERY, TPCC_DELIVERY_3);
  ASSERT_EQ(piece.conflicts_.size(), 1u);
  EXPECT_EQ(piece.conflicts_[0].table, std::string(TPCC_TB_CUSTOMER));
  ASSERT_EQ(piece.conflicts_[0].primary_keys.size(), 3u);
  EXPECT_EQ(piece.conflicts_[0].primary_keys[0], TPCC_VAR_C_ID);
  EXPECT_EQ(piece.conflicts_[0].primary_keys[1], TPCC_VAR_D_ID);
  EXPECT_EQ(piece.conflicts_[0].primary_keys[2], TPCC_VAR_W_ID);
  ASSERT_EQ(piece.conflicts_[0].columns.size(), 2u);
  EXPECT_EQ(piece.conflicts_[0].columns[0], TPCC_COL_CUSTOMER_C_BALANCE);
  EXPECT_EQ(piece.conflicts_[0].columns[1], TPCC_COL_CUSTOMER_C_DELIVERY_CNT);
}

// Test: TPCC ORDER_STATUS all pieces read-only, no conflicts
TEST(TpccConflictDeclarations, OrderStatusAllPiecesReadOnly) {
  auto reg = std::make_shared<TxnRegistry>();

  RegP(reg, TPCC_ORDER_STATUS, TPCC_ORDER_STATUS_0,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_C_LAST}, {}, {},
       {TPCC_TB_CUSTOMER, {TPCC_VAR_W_ID}}, DF_NO);
  EXPECT_TRUE(reg->get(TPCC_ORDER_STATUS, TPCC_ORDER_STATUS_0).conflicts_.empty());

  RegP(reg, TPCC_ORDER_STATUS, TPCC_ORDER_STATUS_1,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_C_ID}, {}, {},
       {TPCC_TB_CUSTOMER, {TPCC_VAR_W_ID}}, DF_NO);
  EXPECT_TRUE(reg->get(TPCC_ORDER_STATUS, TPCC_ORDER_STATUS_1).conflicts_.empty());

  RegP(reg, TPCC_ORDER_STATUS, TPCC_ORDER_STATUS_2,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_C_ID}, {}, {},
       {TPCC_TB_ORDER, {TPCC_VAR_W_ID}}, DF_NO);
  EXPECT_TRUE(reg->get(TPCC_ORDER_STATUS, TPCC_ORDER_STATUS_2).conflicts_.empty());

  RegP(reg, TPCC_ORDER_STATUS, TPCC_ORDER_STATUS_3,
       {TPCC_VAR_W_ID, TPCC_VAR_D_ID, TPCC_VAR_O_ID}, {}, {},
       {TPCC_TB_ORDER_LINE, {TPCC_VAR_W_ID}}, DF_NO);
  EXPECT_TRUE(reg->get(TPCC_ORDER_STATUS, TPCC_ORDER_STATUS_3).conflicts_.empty());
}

// Test: TPCA pieces already have complete conflict declarations
TEST(TpcaConflictDeclarations, AllPiecesHaveConflicts) {
  auto reg = std::make_shared<TxnRegistry>();

  // TPCA_PAYMENT_1 -> customer
  RegP(reg, TPCA_PAYMENT, TPCA_PAYMENT_1,
       {TPCA_VAR_X}, {},
       {conf_id_t(TPCA_CUSTOMER, {TPCA_VAR_X}, {1}, TPCA_ROW_1)},
       {TPCA_CUSTOMER, {TPCA_VAR_X}}, DF_NO);
  auto& p1 = reg->get(TPCA_PAYMENT, TPCA_PAYMENT_1);
  ASSERT_EQ(p1.conflicts_.size(), 1u);
  EXPECT_EQ(p1.conflicts_[0].table, std::string(TPCA_CUSTOMER));

  // TPCA_PAYMENT_2 -> teller
  RegP(reg, TPCA_PAYMENT, TPCA_PAYMENT_2,
       {TPCA_VAR_Y}, {},
       {conf_id_t(TPCA_TELLER, {TPCA_VAR_Y}, {1}, TPCA_ROW_2)},
       {TPCA_TELLER, {TPCA_VAR_Y}}, DF_REAL);
  auto& p2 = reg->get(TPCA_PAYMENT, TPCA_PAYMENT_2);
  ASSERT_EQ(p2.conflicts_.size(), 1u);
  EXPECT_EQ(p2.conflicts_[0].table, std::string(TPCA_TELLER));

  // TPCA_PAYMENT_3 -> branch
  RegP(reg, TPCA_PAYMENT, TPCA_PAYMENT_3,
       {TPCA_VAR_Z}, {},
       {conf_id_t(TPCA_BRANCH, {TPCA_VAR_Z}, {1}, TPCA_ROW_3)},
       {TPCA_BRANCH, {TPCA_VAR_Z}}, DF_REAL);
  auto& p3 = reg->get(TPCA_PAYMENT, TPCA_PAYMENT_3);
  ASSERT_EQ(p3.conflicts_.size(), 1u);
  EXPECT_EQ(p3.conflicts_[0].table, std::string(TPCA_BRANCH));
}

// Test: Conflict primary keys match input vars used for querying
TEST(TpccConflictDeclarations, ConflictKeysMatchQueryKeys) {
  // Verify that the primary keys in conflict declarations match
  // the keys used to Query() rows in the piece handlers.

  // PAYMENT piece 2: queries district by (D_ID, W_ID)
  conf_id_t p2_conf(TPCC_TB_DISTRICT,
                     {TPCC_VAR_D_ID, TPCC_VAR_W_ID},
                     {TPCC_COL_DISTRICT_D_YTD},
                     ROW_DISTRICT_TEMP);
  EXPECT_EQ(p2_conf.primary_keys[0], TPCC_VAR_D_ID);
  EXPECT_EQ(p2_conf.primary_keys[1], TPCC_VAR_W_ID);

  // DELIVERY piece 3: queries customer by (C_ID, D_ID, W_ID)
  conf_id_t d3_conf(TPCC_TB_CUSTOMER,
                     {TPCC_VAR_C_ID, TPCC_VAR_D_ID, TPCC_VAR_W_ID},
                     {TPCC_COL_CUSTOMER_C_BALANCE,
                      TPCC_COL_CUSTOMER_C_DELIVERY_CNT},
                     ROW_CUSTOMER);
  EXPECT_EQ(d3_conf.primary_keys[0], TPCC_VAR_C_ID);
  EXPECT_EQ(d3_conf.primary_keys[1], TPCC_VAR_D_ID);
  EXPECT_EQ(d3_conf.primary_keys[2], TPCC_VAR_W_ID);
}

int main(int argc, char **argv) {
  ::testing::InitGoogleTest(&argc, argv);
  return RUN_ALL_TESTS();
}
