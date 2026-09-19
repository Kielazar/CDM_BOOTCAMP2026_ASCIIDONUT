`default_nettype none

module tt_um_vga_example(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input wire       ena
);

  // ---------------------------------------------------------------
  // VGA sync
  // ---------------------------------------------------------------
  wire hsync, vsync, video_active;
  wire [9:0] pix_x, pix_y;
  reg  [1:0] R, G, B;

  assign uo_out  = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};
  assign uio_out = 0;
  assign uio_oe  = 0;
  wire _unused_ok = &{ena, uio_in, ui_in};

  hvsync_generator hvsync_gen(
    .clk(clk), .reset(~rst_n),
    .hsync(hsync), .vsync(vsync),
    .display_on(video_active),
    .hpos(pix_x), .vpos(pix_y)
  );

  reg vsync_prev;
  always @(posedge clk) vsync_prev <= vsync;
  wire frame_tick = vsync_prev & ~vsync;

  // ---------------------------------------------------------------
  // Fixed-point sin/cos: 6-bit angle (0..63 = 0..360deg), scale64=1.0
  // ---------------------------------------------------------------
  function [6:0] sin_mag; // magnitude for quarter-wave idx 0..15
    input [3:0] idx;
    begin
      case (idx)
        4'd0: sin_mag = 7'd0;   4'd1: sin_mag = 7'd6;
        4'd2: sin_mag = 7'd12;  4'd3: sin_mag = 7'd18;
        4'd4: sin_mag = 7'd24;  4'd5: sin_mag = 7'd30;
        4'd6: sin_mag = 7'd35;  4'd7: sin_mag = 7'd40;
        4'd8: sin_mag = 7'd45;  4'd9: sin_mag = 7'd49;
        4'd10: sin_mag = 7'd52; 4'd11: sin_mag = 7'd56;
        4'd12: sin_mag = 7'd58; 4'd13: sin_mag = 7'd60;
        4'd14: sin_mag = 7'd62; default: sin_mag = 7'd63;
      endcase
    end
  endfunction

  function signed [15:0] sin_lut;
    input [5:0] ang;
    reg [1:0] quad;
    reg [3:0] idx;
    reg [6:0] mag;
    begin
      quad = ang[5:4];
      idx  = ang[3:0];
      mag  = quad[0] ? sin_mag(4'd15 - idx) : sin_mag(idx);
      sin_lut = quad[1] ? -$signed({9'b0, mag}) : $signed({9'b0, mag});
    end
  endfunction

  function signed [15:0] cos_lut;
    input [5:0] ang;
    begin
      cos_lut = sin_lut(ang + 6'd16);
    end
  endfunction

  function signed [15:0] mul; // (a*b)>>>6, scale64 fixed-point multiply
    input signed [15:0] a;
    input signed [15:0] b;
    reg signed [31:0] p;
    begin
      p = a * b;
      mul = p >>> 6;
    end
  endfunction

  // ---------------------------------------------------------------
  // Bayer 8x8 ordered-dither ROM (for density shading)
  // ---------------------------------------------------------------
  function [5:0] bayer;
    input [2:0] bx, by;
    begin
      case (by)
        3'd0: case (bx) 3'd0:bayer=6'd0; 3'd1:bayer=6'd32; 3'd2:bayer=6'd8; 3'd3:bayer=6'd40; 3'd4:bayer=6'd2; 3'd5:bayer=6'd34; 3'd6:bayer=6'd10; default:bayer=6'd42; endcase
        3'd1: case (bx) 3'd0:bayer=6'd48; 3'd1:bayer=6'd16; 3'd2:bayer=6'd56; 3'd3:bayer=6'd24; 3'd4:bayer=6'd50; 3'd5:bayer=6'd18; 3'd6:bayer=6'd58; default:bayer=6'd26; endcase
        3'd2: case (bx) 3'd0:bayer=6'd12; 3'd1:bayer=6'd44; 3'd2:bayer=6'd4; 3'd3:bayer=6'd36; 3'd4:bayer=6'd14; 3'd5:bayer=6'd46; 3'd6:bayer=6'd6; default:bayer=6'd38; endcase
        3'd3: case (bx) 3'd0:bayer=6'd60; 3'd1:bayer=6'd28; 3'd2:bayer=6'd52; 3'd3:bayer=6'd20; 3'd4:bayer=6'd62; 3'd5:bayer=6'd30; 3'd6:bayer=6'd54; default:bayer=6'd22; endcase
        3'd4: case (bx) 3'd0:bayer=6'd3; 3'd1:bayer=6'd35; 3'd2:bayer=6'd11; 3'd3:bayer=6'd43; 3'd4:bayer=6'd1; 3'd5:bayer=6'd33; 3'd6:bayer=6'd9; default:bayer=6'd41; endcase
        3'd5: case (bx) 3'd0:bayer=6'd51; 3'd1:bayer=6'd19; 3'd2:bayer=6'd59; 3'd3:bayer=6'd27; 3'd4:bayer=6'd49; 3'd5:bayer=6'd17; 3'd6:bayer=6'd57; default:bayer=6'd25; endcase
        3'd6: case (bx) 3'd0:bayer=6'd15; 3'd1:bayer=6'd47; 3'd2:bayer=6'd7; 3'd3:bayer=6'd39; 3'd4:bayer=6'd13; 3'd5:bayer=6'd45; 3'd6:bayer=6'd5; default:bayer=6'd37; endcase
        default: case (bx) 3'd0:bayer=6'd63; 3'd1:bayer=6'd31; 3'd2:bayer=6'd55; 3'd3:bayer=6'd23; 3'd4:bayer=6'd61; 3'd5:bayer=6'd29; 3'd6:bayer=6'd53; default:bayer=6'd21; endcase
      endcase
    end
  endfunction

  // ---------------------------------------------------------------
  // Grid / frame buffer: 40 cols x 15 rows, 4-bit brightness (0=bg)
  // ---------------------------------------------------------------
  localparam GRID_W = 40;
  localparam GRID_H = 15;
  localparam HALFW  = 20;
  localparam HALFH  = 7;

  reg [3:0] lum_buf [0:GRID_H-1][0:GRID_W-1];

  // Rotation angles (advance each frame)
  reg [5:0] angA, angB;

  // FSM: CLEAR buffer -> COMPUTE donut points -> IDLE until next frame
  localparam ST_IDLE = 0, ST_CLEAR = 1, ST_COMPUTE = 2;
  reg [1:0] state;

  reg [3:0] clear_r;
  reg [5:0] clear_c;

  reg [3:0] t_idx; // 0..15 -> theta
  reg [5:0] p_idx; // 0..63 -> phi

  wire [5:0] theta_ang = {t_idx, 2'b00};
  wire [5:0] phi_ang   = p_idx;

  wire signed [15:0] costh = cos_lut(theta_ang);
  wire signed [15:0] sinth = sin_lut(theta_ang);
  wire signed [15:0] cosph = cos_lut(phi_ang);
  wire signed [15:0] sinph = sin_lut(phi_ang);
  wire signed [15:0] sinA  = sin_lut(angA);
  wire signed [15:0] cosA  = cos_lut(angA);
  wire signed [15:0] sinB  = sin_lut(angB);
  wire signed [15:0] cosB  = cos_lut(angB);

  wire signed [15:0] circlex = 16'sd128 + costh; // R2=2,R1=1 (scale64)
  wire signed [15:0] circley = sinth;

  wire signed [15:0] xterm1 = mul(cosB, cosph) + mul(mul(sinA, sinB), sinph);
  wire signed [15:0] xval   = mul(circlex, xterm1) - mul(circley, mul(cosA, sinB));

  wire signed [15:0] yterm1 = mul(sinB, cosph) - mul(mul(sinA, cosB), sinph);
  wire signed [15:0] yval   = mul(circlex, yterm1) + mul(circley, mul(cosA, cosB));

  wire signed [15:0] Lval =
      mul(cosph, mul(costh, sinB))
    - mul(cosA,  mul(costh, sinph))
    - mul(sinA, sinth)
    + mul(cosB, mul(cosA, sinth) - mul(costh, mul(sinA, sinph)));

  wire signed [15:0] xp_s = HALFW + (xval >>> 4);
  wire signed [15:0] yp_s = HALFH - (yval >>> 5);

  wire signed [15:0] lshift = Lval >>> 4;
  wire [3:0] lvl_clamped = lshift[15] ? 4'd0 :
                           (lshift > 15'd12) ? 4'd13 : (lshift[3:0] + 4'd1);
  wire [3:0] new_level = Lval[15] ? 4'd0 : lvl_clamped;

  wire in_range = (xp_s >= 0) && (xp_s < GRID_W) && (yp_s >= 0) && (yp_s < GRID_H);

  integer ri, ci;
  always @(posedge clk) begin
    if (~rst_n) begin
      state <= ST_IDLE;
      angA  <= 0;
      angB  <= 0;
      for (ri = 0; ri < GRID_H; ri = ri + 1)
        for (ci = 0; ci < GRID_W; ci = ci + 1)
          lum_buf[ri][ci] <= 0;
    end else begin
      case (state)
        ST_IDLE: begin
          if (frame_tick) begin
            angA    <= angA + 1;
            angB    <= angB + 2;
            clear_r <= 0;
            clear_c <= 0;
            state   <= ST_CLEAR;
          end
        end

        ST_CLEAR: begin
          lum_buf[clear_r][clear_c] <= 0;
          if (clear_c == GRID_W - 1) begin
            clear_c <= 0;
            if (clear_r == GRID_H - 1) begin
              t_idx <= 0;
              p_idx <= 0;
              state <= ST_COMPUTE;
            end else
              clear_r <= clear_r + 1;
          end else
            clear_c <= clear_c + 1;
        end

        ST_COMPUTE: begin
          if (in_range)
            lum_buf[yp_s[3:0]][xp_s[5:0]] <= new_level;

          if (p_idx == 63) begin
            p_idx <= 0;
            if (t_idx == 15)
              state <= ST_IDLE;
            else
              t_idx <= t_idx + 1;
          end else
            p_idx <= p_idx + 1;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------
  wire [5:0] col = pix_x[9:4]; // pix_x / 16
  wire [3:0] row = pix_y[8:5]; // pix_y / 32
  wire [2:0] subx = pix_x[3:1];
  wire [2:0] suby = pix_y[4:2];

  wire on_grid = video_active && (col < GRID_W) && (row < GRID_H);
  wire [3:0] level = on_grid ? lum_buf[row[3:0]][col] : 4'd0;
  wire [6:0] threshold = level * 5;
  wire pixel_on = on_grid && (level != 0) && (bayer(subx, suby) < threshold);

  always @* begin
    if (pixel_on) begin
      R = 2'b00; G = 2'b11; B = 2'b00; // green terminal glow
    end else begin
      R = 2'b00; G = 2'b00; B = 2'b00;
    end
    if (!video_active) begin R = 0; G = 0; B = 0; end
  end

endmodule
