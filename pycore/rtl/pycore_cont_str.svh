// pycore_cont_str.svh — FORMAT_SIMPLE / CONVERT_VALUE / BUILD_STRING.
// Included inside pycore_core's unique case (container_op_r). Do not compile alone.
//
// Ceilings (v1):
//   FORMAT_SIMPLE / CONVERT_VALUE: INT (≤15-char decimal SHORT_STR), BOOL,
//   None, SHORT_STR/LONG_STR identity. Other tags → TYPE.
//   CONVERT_VALUE oparg 2/3 (repr/ascii): INT/BOOL/None same as str; SHORT_STR
//   gets single-quote wrapping when result still fits in SHORT_STR; else TYPE.
//   BUILD_STRING: all pieces SHORT_STR and total length ≤15; else TYPE.

                        CONT_FORMAT_SIMPLE: begin
                            unique case (container_phase_r)
                                CP_INIT: begin
                                    begin
                                        logic        fmt_ok;
                                        logic [PYCORE_ENTRY_WIDTH-1:0] fmt_entry;
                                        fmt_ok = 1'b0;
                                        fmt_entry = pycore_make_entry(PY_TAG_OBJECT, '0);
                                        if (pycore_is_none(cont_rs1_tag, cont_rs1_val)) begin
                                            fmt_ok = 1'b1;
                                            fmt_entry = pycore_make_entry(
                                                PY_TAG_SHORT_STR, PY_STR_NONE);
                                        end else if (cont_rs1_tag == PY_TAG_BOOL) begin
                                            fmt_ok = 1'b1;
                                            fmt_entry = pycore_make_entry(
                                                PY_TAG_SHORT_STR,
                                                cont_rs1_val[0] ? PY_STR_TRUE
                                                                : PY_STR_FALSE);
                                        end else if (cont_rs1_tag == PY_TAG_INT) begin
                                            pycore_int_to_short_str(
                                                cont_rs1_val[63:0], fmt_ok, fmt_entry);
                                        end else if (pycore_is_string_tag(cont_rs1_tag)) begin
                                            fmt_ok = 1'b1;
                                            fmt_entry = pycore_make_entry(
                                                cont_rs1_tag, cont_rs1_val);
                                        end
                                        if (!fmt_ok) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                            container_wb_data_r <= fmt_entry;
                                            fetch_skip_r        <= 1'b1;
                                            container_phase_r   <= CP_DONE;
                                        end
                                    end
                                end
                                CP_DONE: ;
                                default: ;
                            endcase
                        end // CONT_FORMAT_SIMPLE

                        CONT_CONVERT_VALUE: begin
                            unique case (container_phase_r)
                                CP_INIT: begin
                                    begin
                                        logic        cv_ok;
                                        logic [PYCORE_ENTRY_WIDTH-1:0] cv_entry;
                                        logic [3:0]  slen;
                                        logic [119:0] payload;
                                        logic [119:0] quoted;
                                        int qi;
                                        cv_ok = 1'b0;
                                        cv_entry = pycore_make_entry(PY_TAG_OBJECT, '0);
                                        // oparg: 1=str, 2=repr, 3=ascii
                                        if ((cur_arg_r != 32'd1) &&
                                            (cur_arg_r != 32'd2) &&
                                            (cur_arg_r != 32'd3)) begin
                                            container_type_trap_r <= 1'b1;
                                        end else if (pycore_is_none(cont_rs1_tag,
                                                                    cont_rs1_val)) begin
                                            cv_ok = 1'b1;
                                            cv_entry = pycore_make_entry(
                                                PY_TAG_SHORT_STR, PY_STR_NONE);
                                        end else if (cont_rs1_tag == PY_TAG_BOOL) begin
                                            cv_ok = 1'b1;
                                            cv_entry = pycore_make_entry(
                                                PY_TAG_SHORT_STR,
                                                cont_rs1_val[0] ? PY_STR_TRUE
                                                                : PY_STR_FALSE);
                                        end else if (cont_rs1_tag == PY_TAG_INT) begin
                                            pycore_int_to_short_str(
                                                cont_rs1_val[63:0], cv_ok, cv_entry);
                                        end else if (cont_rs1_tag == PY_TAG_SHORT_STR) begin
                                            if ((cur_arg_r == 32'd1)) begin
                                                // str(s) identity
                                                cv_ok = 1'b1;
                                                cv_entry = pycore_make_entry(
                                                    PY_TAG_SHORT_STR, cont_rs1_val);
                                            end else begin
                                                // repr/ascii: wrap in single quotes
                                                slen = pycore_short_str_size(cont_rs1_val);
                                                if ((slen > PYCORE_SHORT_STR_MAX_BYTES) ||
                                                    (slen + 4'd2 > 4'd15)) begin
                                                    cv_ok = 1'b0;
                                                end else begin
                                                    payload = pycore_short_str_payload(
                                                        cont_rs1_val);
                                                    quoted = '0;
                                                    quoted[119-:8] = 8'h27; // '
                                                    for (qi = 0; qi < 15; qi++) begin
                                                        if (qi < slen) begin
                                                            quoted[119-((qi+1)*8)-:8] =
                                                                payload[119-(qi*8)-:8];
                                                        end
                                                    end
                                                    quoted[119-((slen+1)*8)-:8] = 8'h27;
                                                    cv_ok = 1'b1;
                                                    cv_entry = pycore_make_short_str_entry(
                                                        slen + 4'd2, quoted);
                                                end
                                            end
                                        end else if (cont_rs1_tag == PY_TAG_LONG_STR) begin
                                            // Identity for str; repr of LONG_STR
                                            // needs escaping/alloc — TYPE for now.
                                            if (cur_arg_r == 32'd1) begin
                                                cv_ok = 1'b1;
                                                cv_entry = pycore_make_entry(
                                                    PY_TAG_LONG_STR, cont_rs1_val);
                                            end
                                        end
                                        if ((cur_arg_r == 32'd1) ||
                                            (cur_arg_r == 32'd2) ||
                                            (cur_arg_r == 32'd3)) begin
                                            if (!cv_ok) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                container_wb_we_r   <= 1'b1;
                                                container_wb_addr_r <=
                                                    RF_AW'(tos_r - RF_AW'(1));
                                                container_wb_data_r <= cv_entry;
                                                fetch_skip_r        <= 1'b1;
                                                container_phase_r   <= CP_DONE;
                                            end
                                        end
                                    end
                                end
                                CP_DONE: ;
                                default: ;
                            endcase
                        end // CONT_CONVERT_VALUE

                        CONT_BUILD_STRING: begin
                            unique case (container_phase_r)
                                CP_INIT: begin
                                    // count==0 → ""; count==1 → identity leave;
                                    // else start accum from first piece.
                                    if (container_count_r == 7'd0) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r);
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_SHORT_STR, PY_STR_EMPTY);
                                        tos_r             <= tos_r + RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end else if (container_count_r == 7'd1) begin
                                        // Leave the single string on the stack.
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end else begin
                                        // Read first piece into container_val/tag.
                                        container_rf_addr_r <=
                                            RF_AW'(tos_r - RF_AW'(container_count_r));
                                        container_idx_r   <= 7'd1;
                                        container_phase_r <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    // Latch accum from RF read of first piece.
                                    if (pycore_get_tag(rf_rs1) != PY_TAG_SHORT_STR) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= PY_TAG_SHORT_STR;
                                        container_val_r <= pycore_get_val(rf_rs1);
                                        // Issue read of next piece.
                                        container_rf_addr_r <=
                                            RF_AW'(tos_r - RF_AW'(container_count_r) +
                                                   RF_AW'(container_idx_r));
                                        container_phase_r <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    // Concat accum || next; both must be SHORT_STR
                                    // and result ≤15 bytes.
                                    begin
                                        logic [3:0] la;
                                        logic [3:0] lb;
                                        logic [3:0] out_len;
                                        logic [119:0] pa;
                                        logic [119:0] pb;
                                        logic [119:0] outp;
                                        logic [3:0] ntag;
                                        logic [PYCORE_VAL_WIDTH-1:0] out_val;
                                        int ci;
                                        ntag = pycore_get_tag(rf_rs1);
                                        if (ntag != PY_TAG_SHORT_STR) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            la = pycore_short_str_size(container_val_r);
                                            lb = pycore_short_str_size(
                                                pycore_get_val(rf_rs1));
                                            if ((la > PYCORE_SHORT_STR_MAX_BYTES) ||
                                                (lb > PYCORE_SHORT_STR_MAX_BYTES) ||
                                                ({1'b0, la} + {1'b0, lb} >
                                                 5'(PYCORE_SHORT_STR_MAX_BYTES))) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                out_len = la + lb;
                                                pa = pycore_short_str_payload(
                                                    container_val_r);
                                                pb = pycore_short_str_payload(
                                                    pycore_get_val(rf_rs1));
                                                outp = '0;
                                                for (ci = 0; ci < 15; ci++) begin
                                                    if (ci < la) begin
                                                        outp[119-(ci*8)-:8] =
                                                            pa[119-(ci*8)-:8];
                                                    end else if (ci < out_len) begin
                                                        outp[119-(ci*8)-:8] =
                                                            pb[119-((ci-la)*8)-:8];
                                                    end
                                                end
                                                out_val = {out_len, outp, 4'b0};
                                                container_val_r <= out_val;
                                                container_tag_r <= PY_TAG_SHORT_STR;
                                                if (container_idx_r + 7'd1 >=
                                                        container_count_r) begin
                                                    container_wb_we_r   <= 1'b1;
                                                    container_wb_addr_r <=
                                                        RF_AW'(tos_r -
                                                               RF_AW'(container_count_r));
                                                    container_wb_data_r <=
                                                        pycore_make_entry(
                                                            PY_TAG_SHORT_STR, out_val);
                                                    tos_r <= tos_r -
                                                             RF_AW'(container_count_r) +
                                                             RF_AW'(1);
                                                    fetch_skip_r      <= 1'b1;
                                                    container_phase_r <= CP_DONE;
                                                end else begin
                                                    container_idx_r <=
                                                        container_idx_r + 7'd1;
                                                    container_rf_addr_r <=
                                                        RF_AW'(tos_r -
                                                               RF_AW'(container_count_r) +
                                                               RF_AW'(container_idx_r +
                                                                      7'd1));
                                                    // Wait one cycle for RF settle.
                                                    container_phase_r <= CP_HDR;
                                                end
                                            end
                                        end
                                    end
                                end

                                CP_HDR: begin
                                    // Next piece is now on rf_rs1.
                                    container_phase_r <= CP_TAG;
                                end

                                CP_DONE: ;
                                default: ;
                            endcase
                        end // CONT_BUILD_STRING
