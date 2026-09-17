// pycore_cont_closure.svh — MAKE_CELL / LOAD_DEREF / STORE_DEREF /
// COPY_FREE_VARS / SET_FUNCTION_ATTRIBUTE (flag 8).
// Included inside pycore_core's unique case (container_op_r).
                        CONT_MAKE_CELL: begin
                            unique case (container_phase_r)
                                CP_INIT: begin
                                    if (pycore_heap_end(
                                            heap_ptr_r, PYCORE_OBJ_CELL_BYTES) >
                                            PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_base_r <=
                                            pycore_heap_place(
                                                heap_ptr_r,
                                                PYCORE_OBJ_CELL_BYTES);
                                        heap_ptr_r <= pycore_heap_end(
                                            heap_ptr_r, PYCORE_OBJ_CELL_BYTES);
                                        container_dmem_addr_r <=
                                            pycore_heap_place(
                                                heap_ptr_r,
                                                PYCORE_OBJ_CELL_BYTES);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <=
                                            pycore_pack_ob_head(
                                                PY_OBK_CELL, 32'd0, 64'd0);
                                        container_dmem_pending_r <= 1'b1;
                                        container_probe_r <= 32'd0;
                                        container_phase_r <= CP_HDR;
                                    end
                                end
                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_r == 32'd0) begin
                                            container_dmem_addr_r    <=
                                                container_base_r + 32'd16;
                                            container_dmem_we_r      <= 1'b1;
                                            container_dmem_wdata_r   <=
                                                {124'b0, PY_TAG_OBJECT};
                                            container_dmem_pending_r <= 1'b1;
                                            container_probe_r        <= 32'd1;
                                        end else if (container_probe_r == 32'd1) begin
                                            container_dmem_addr_r    <=
                                                pycore_obj_field_val_addr(
                                                    container_base_r, 32'd0);
                                            container_dmem_we_r      <= 1'b1;
                                            container_dmem_wdata_r   <=
                                                cont_rs1_val;
                                            container_dmem_pending_r <= 1'b1;
                                            container_probe_r        <= 32'd2;
                                        end else if (container_probe_r == 32'd2) begin
                                            container_dmem_addr_r    <=
                                                pycore_obj_field_tag_addr(
                                                    container_base_r, 32'd0);
                                            container_dmem_we_r      <= 1'b1;
                                            container_dmem_wdata_r   <=
                                                {124'b0, cont_rs1_tag};
                                            container_dmem_pending_r <= 1'b1;
                                            container_probe_r        <= 32'd3;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, cur_locals_base_r} +
                                                {5'b0, cur_arg_r[7:0]});
                                            container_wb_data_r <=
                                                pycore_make_entry(
                                                    PY_TAG_OBJECT,
                                                    {{96{1'b0}},
                                                     container_base_r});
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end
                                CP_DONE: ;
                                default: ;
                            endcase
                        end

                        CONT_LOAD_DEREF: begin
                            unique case (container_phase_r)
                                CP_INIT: begin
                                    if (cont_rs1_tag != PY_TAG_OBJECT) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_dmem_addr_r    <=
                                            cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end
                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (pycore_ob_kind(container_rd_data_r) !=
                                                PY_OBK_CELL) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_obj_field_val_addr(
                                                    cont_rs1_addr, 32'd0);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_VAL;
                                        end
                                    end
                                end
                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_obj_field_tag_addr(
                                                cont_rs1_addr, 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_TAG;
                                    end
                                end
                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (pycore_is_uninit(
                                                container_rd_data_r[3:0],
                                                container_val_r)) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <=
                                                RF_AW'({2'b0, tos_r});
                                            container_wb_data_r <=
                                                pycore_make_entry(
                                                    container_rd_data_r[3:0],
                                                    container_val_r);
                                            tos_r             <= tos_r + RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end
                                CP_DONE: ;
                                default: ;
                            endcase
                        end

                        CONT_STORE_DEREF: begin
                            unique case (container_phase_r)
                                CP_INIT: begin
                                    container_val_r   <= cont_rs1_val;
                                    container_tag_r   <= cont_rs1_tag;
                                    container_probe_r <= 32'd0;
                                    container_rf_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} +
                                        {5'b0, cur_arg_r[7:0]});
                                    container_phase_r <= CP_HDR;
                                end
                                CP_HDR: begin
                                    if (cont_rf_rs1_tag != PY_TAG_OBJECT) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_base_r         <=
                                            cont_rf_rs1_val[31:0];
                                        container_dmem_addr_r    <=
                                            cont_rf_rs1_val[31:0];
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end
                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_r == 32'd0) begin
                                            if (pycore_ob_kind(
                                                    container_rd_data_r) !=
                                                    PY_OBK_CELL) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                container_dmem_addr_r <=
                                                    pycore_obj_field_val_addr(
                                                        container_base_r, 32'd0);
                                                container_dmem_we_r      <= 1'b1;
                                                container_dmem_wdata_r   <=
                                                    container_val_r;
                                                container_dmem_pending_r <= 1'b1;
                                                container_probe_r        <= 32'd1;
                                            end
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_obj_field_tag_addr(
                                                    container_base_r, 32'd0);
                                            container_dmem_we_r      <= 1'b1;
                                            container_dmem_wdata_r   <=
                                                {124'b0, container_tag_r};
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_TAG;
                                        end
                                    end
                                end
                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end
                                CP_DONE: ;
                                default: ;
                            endcase
                        end

                        CONT_COPY_FREE: begin
                            unique case (container_phase_r)
                                CP_INIT: begin
                                    if (cur_arg_r == 32'd0) begin
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end else if (cont_closure_size <
                                                 {32'b0, cur_arg_r}) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_slot_count_r <= cur_arg_r;
                                        container_probe_r      <= 32'd0;
                                        container_dmem_addr_r  <=
                                            pycore_tuple_val_addr(
                                                cont_closure_addr, 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end
                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_tuple_tag_addr(
                                                cont_closure_addr,
                                                container_probe_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_TAG;
                                    end
                                end
                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <=
                                            tos_r - RF_AW'(container_slot_count_r[RF_AW-1:0])
                                            + RF_AW'(container_probe_r[RF_AW-1:0]);
                                        container_wb_data_r <=
                                            pycore_make_entry(
                                                container_rd_data_r[3:0],
                                                container_val_r);
                                        if ((container_probe_r + 32'd1) ==
                                                container_slot_count_r) begin
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_probe_r <=
                                                container_probe_r + 32'd1;
                                            container_dmem_addr_r <=
                                                pycore_tuple_val_addr(
                                                    cont_closure_addr,
                                                    container_probe_r + 32'd1);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_VAL;
                                        end
                                    end
                                end
                                CP_DONE: ;
                                default: ;
                            endcase
                        end

                        CONT_SET_FUNC_ATTR: begin
                            unique case (container_phase_r)
                                CP_INIT: begin
                                    if (cur_arg_r != 32'd8) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_rs1_tag !=
                                                 PY_TAG_CODE_OBJECT) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_rs2_tag !=
                                                 PY_TAG_TUPLE) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (pycore_heap_end(
                                            heap_ptr_r,
                                            PYCORE_OBJ_FUNCTION_BYTES) >
                                            PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_base_r <=
                                            pycore_heap_place(
                                                heap_ptr_r,
                                                PYCORE_OBJ_FUNCTION_BYTES);
                                        heap_ptr_r <= pycore_heap_end(
                                            heap_ptr_r,
                                            PYCORE_OBJ_FUNCTION_BYTES);
                                        container_dmem_addr_r <=
                                            pycore_heap_place(
                                                heap_ptr_r,
                                                PYCORE_OBJ_FUNCTION_BYTES);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <=
                                            pycore_pack_ob_head(
                                                PY_OBK_FUNCTION, 32'd0, 64'd0);
                                        container_dmem_pending_r <= 1'b1;
                                        container_probe_r <= 32'd0;
                                        container_phase_r <= CP_HDR;
                                    end
                                end
                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_r == 32'd0) begin
                                            container_dmem_addr_r    <=
                                                container_base_r + 32'd16;
                                            container_dmem_we_r      <= 1'b1;
                                            container_dmem_wdata_r   <=
                                                {124'b0, PY_TAG_OBJECT};
                                            container_dmem_pending_r <= 1'b1;
                                            container_probe_r        <= 32'd1;
                                        end else if (container_probe_r == 32'd1) begin
                                            container_dmem_addr_r    <=
                                                pycore_obj_field_val_addr(
                                                    container_base_r, 32'd0);
                                            container_dmem_we_r      <= 1'b1;
                                            container_dmem_wdata_r   <=
                                                cont_rs1_val;
                                            container_dmem_pending_r <= 1'b1;
                                            container_probe_r        <= 32'd2;
                                        end else if (container_probe_r == 32'd2) begin
                                            container_dmem_addr_r    <=
                                                pycore_obj_field_tag_addr(
                                                    container_base_r, 32'd0);
                                            container_dmem_we_r      <= 1'b1;
                                            container_dmem_wdata_r   <=
                                                {124'b0, PY_TAG_CODE_OBJECT};
                                            container_dmem_pending_r <= 1'b1;
                                            container_probe_r        <= 32'd3;
                                        end else if (container_probe_r == 32'd3) begin
                                            container_dmem_addr_r    <=
                                                pycore_obj_field_val_addr(
                                                    container_base_r, 32'd1);
                                            container_dmem_we_r      <= 1'b1;
                                            container_dmem_wdata_r   <=
                                                cont_rs2_val;
                                            container_dmem_pending_r <= 1'b1;
                                            container_probe_r        <= 32'd4;
                                        end else if (container_probe_r == 32'd4) begin
                                            container_dmem_addr_r    <=
                                                pycore_obj_field_tag_addr(
                                                    container_base_r, 32'd1);
                                            container_dmem_we_r      <= 1'b1;
                                            container_dmem_wdata_r   <=
                                                {124'b0, PY_TAG_TUPLE};
                                            container_dmem_pending_r <= 1'b1;
                                            container_probe_r        <= 32'd5;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <=
                                                tos_r - RF_AW'(2);
                                            container_wb_data_r <=
                                                pycore_make_entry(
                                                    PY_TAG_OBJECT,
                                                    {{96{1'b0}},
                                                     container_base_r});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end
                                CP_DONE: ;
                                default: ;
                            endcase
                        end
