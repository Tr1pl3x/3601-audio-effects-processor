## Added Files

---

### 1. `programmable_logic/audio_effects.vhd`

**Purpose:** Effects coordinator with 6-way multiplexer

**What it does:**
- Receives audio from FIFO
- Feeds audio to **all 6 effects in parallel**
- Multiplexer selects which effect’s output goes to DMA
- Effect selection controlled by 3-bit `effect_selector` signal from ARM processor

```
                    ┌──────────┐
                    │   None   │ (bypass)
                    ├──────────┤
FIFO → All effects →│   Echo   │ → MUX (selects one) → AXI DMA → ARM
       in parallel  │   Gain   │      ↑
                    │  Speed   │   3-bit selector
                    │ Clipping │   from ARM
                    │ Flanger  │
                    └──────────┘
```

**Current status:**
- ✅ **Gain effect**: Fully implemented (volume control)
- 🔲 **Echo, Speed, Clipping, Flanger**: Placeholders (pass-through - your job to implement!)

**Key MUX code:**

```vhdl
effect_mux : process(effect_selector, bypass_out, echo_out, gain_out, ...)
begin    case effect_selector is        when "000" => audio_out <= bypass_out;    -- None        when "001" => audio_out <= echo_out;      -- Echo (TODO)        when "010" => audio_out <= gain_out;      -- Gain (working)        when "011" => audio_out <= speed_out;     -- Speed (TODO)        when "100" => audio_out <= clipping_out;  -- Clipping (TODO)        when "101" => audio_out <= flanger_out;   -- Flanger (TODO)        when others => audio_out <= bypass_out;
    end case;
end process;
```

### 2. `programmable_logic/gain_effect.vhd`

**Purpose**: Example effect - volume control

**Why this exists:** Reference implementation showing the 3-stage pipeline structure all effects must follow.

**Key features:**
- Q16.16 fixed-point multiplication (audio × gain coefficient)
- 3-stage pipeline: Multiply → Scale → Saturate
- Saturation prevents overflow/clipping

---

### Modified Files

### 3. `programmable_logic/ctrl_bus.vhd`

**What changed:**
- Added `cb_effect_sel` output port (3 bits)
- Connected to `slv_reg0[2:0]` (bits 2-0 of control register at offset 0x00)

**Why:** ARM processor needs a way to select which effect is active. It writes to this register via AXI4-Lite.

### 4. `programmable_logic/audio_pipeline.vhd`

**What changed:**
- Added `sig_effect_sel` signal
- Routed from `ctrl_bus` → `audio_effects`

**Why:** Bridges the effect selector from control register to MUX selector input.

### 5. `programmable_logic/params.vhd`

**What changed:**
- Updated component declarations for `audio_effects` and `ctrl_bus`

**Why:** Component ports must match entity definitions, or synthesis fails.

### 6. `processor_logic/app-sd-test/src/helloworld.c`

**What changed:**
- Added effect selector constants (`EFFECT_NONE`, `EFFECT_GAIN`, etc.)
- Added functions: `set_audio_effect()`, `get_audio_effect()`, `cycle_to_next_effect()`
- Added gain control functions: `set_audio_gain()`, `get_audio_gain()`

**Why:** Provides C API for controlling effects from ARM processor.