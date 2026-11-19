# \# ECE 3610 Final Project: FPGA Chladni Plate Synthesizer \& Visualizer

# 

# A real-time audio-visual Chladni plate synthesizer implemented in VHDL on the \*\*Digilent Basys 3 (Artix-7 FPGA)\*\*. The system pairs a dual-mode audio synthesizer (built-in Song ROM playback or interactive UART frequency synthesis) with a real-time 2D damped wave solver (`64 × 64` grid) rendered as a live `640 × 480` heat map over VGA.

# 

# \---

# 

# \## Repository Structure

# 

# ```text

# ECE3610FinalProject/

# ├── src/

# │   ├── Top.vhd                    # Top-level structural wiring \& clock/reset integration

# │   ├── UartFreqParser.vhd         # 9600-baud UART transceiver \& frequency input parser

# │   ├── AudioModeController.vhd    # Dual-mode audio synthesizer \& PWM audio generator

# │   ├── pdeSolver.vhd              # 2D damped wave equation solver (64x64 plate grid)

# │   └── vgaChladniDisplay.vhd      # 640x480 @ 60 Hz VGA timing \& thermal color mapper

# ├── constrs/

# │   └── const.xdc                  # Basys 3 pin assignments \& 100 MHz clock constraint

# ├── ip/

# │   └── carelessWhisper.coe        # Block RAM initialization file for built-in melody ROM

# └── blk\_mem\_gen\_0\_2/

# &#x20;   └── blk\_mem\_gen\_0.xci          # Xilinx Block Memory Generator IP definition

# ```

# 

# \---

# 

# \## Hardware \& Software Requirements

# 

# \### FPGA Board \& Peripherals

# \* \*\*FPGA Development Board:\*\* Digilent Basys 3 (`xc7a35tcpg236-1`, 100 MHz onboard oscillator)

# \* \*\*Audio Output:\*\* Digilent \*\*PmodAMP2\*\* (connected to Pmod Header \*\*JA\*\*) + 3.5 mm speaker/headphones

# \* \*\*Video Output:\*\* Standard \*\*VGA Display\*\* (`640 × 480 @ 60 Hz`) via the Basys 3 onboard 15-pin VGA port

# \* \*\*Host Interface:\*\* Micro-USB cable (powers the board, programs the FPGA, and carries USB-UART serial traffic)

# 

# \### Software Tools

# \* \*\*Xilinx / AMD Vivado Design Suite\*\* (for synthesis, implementation, IP generation, and bitstream programming)

# \* \*\*Serial Terminal Emulator\*\* (PuTTY, Tera Term, or `screen` configured to `9600 baud, 8N1`)

# 

# \---

# 

# \## Vivado Project Setup \& Build Instructions

# 

# 1\. \*\*Clone the Repository\*\*

# &#x20;  ```bash

# &#x20;  git clone \[https://github.com/isaacVenegasMacevschi/ECE3610FinalProject.git](https://github.com/isaacVenegasMacevschi/ECE3610FinalProject.git)

# &#x20;  cd ECE3610FinalProject

# &#x20;  ```

# 

# 2\. \*\*Create a New Vivado RTL Project\*\*

# &#x20;  \* Open Vivado and select \*\*Create Project\*\* → \*\*RTL Project\*\*.

# &#x20;  \* Set the target part to \*\*Basys 3 (`xc7a35tcpg236-1`)\*\*.

# 

# 3\. \*\*Add Design Sources \& Constraints\*\*

# &#x20;  \* \*\*Design Sources:\*\* Click \*\*Add Sources\*\* → \*\*Add or create design sources\*\*, select all `.vhd` files inside `src/`, and set `Top` (`src/Top.vhd`) as the top-level module.

# &#x20;  \* \*\*Constraints:\*\* Click \*\*Add Sources\*\* → \*\*Add or create constraints\*\* and add `constrs/const.xdc`.

# &#x20;    \* \*Note:\* Inspect `constrs/const.xdc` if you wish to confirm or reassign the exact switch/button pins used for `swMode` and `syncReset`.

# 

# 4\. \*\*Import \& Generate the Block RAM Song ROM IP\*\*

# &#x20;  \* Click \*\*Add Sources\*\* → \*\*Add or create design sources\*\* and select `blk\_mem\_gen\_0\_2/blk\_mem\_gen\_0.xci`.

# &#x20;  \* In the \*\*Sources\*\* panel, double-click `blk\_mem\_gen\_0` to open the IP customization wizard.

# &#x20;  \* Navigate to the \*\*Other Options\*\* tab, ensure \*\*Load Init File\*\* is checked, and click \*\*Browse\*\* to point \*\*Coe File\*\* to `ip/carelessWhisper.coe`.

# &#x20;  \* Click \*\*OK\*\*, then click \*\*Generate\*\* in the \*Generate Output Products\* dialog so Vivado synthesizes the ROM cleanly on your machine.

# 

# 5\. \*\*Generate Bitstream \& Program the Basys 3\*\*

# &#x20;  \* Run \*\*Run Synthesis\*\* → \*\*Run Implementation\*\* → \*\*Generate Bitstream\*\*.

# &#x20;  \* Power on the Basys 3 and connect it to your PC via Micro-USB.

# &#x20;  \* Open \*\*Hardware Manager\*\* → \*\*Open Target\*\* → \*\*Auto Connect\*\*, then click \*\*Program Device\*\* and load the generated `.bit` file.

# 

# \---

# 

# \## Controls \& Operating Modes

# 

# \*(Verify exact switch/button pin labels against `constrs/const.xdc`.)\*

# 

# | Control / Port | Basys 3 Pin / Header | Function |

# | :--- | :--- | :--- |

# | \*\*`SW0` (`swMode`)\*\* | Slide Switch 0 | \*\*Audio \& Exciter Mode Select:\*\*<br>• `0` (DOWN): Plays built-in Song ROM melody (`carelessWhisper.coe`)<br>• `1` (UP): Custom UART frequency mode (`200 – 20,000 Hz`) |

# | \*\*`BTNC` (`syncReset`)\*\* | Center Pushbutton | \*\*Synchronous Reset:\*\* Resets wave grid, audio phase, and UART state |

# | \*\*Pmod `JA`\*\* | Top Row (`JA1–JA4`) | \*\*PmodAMP2 Audio Interface:\*\* PWM audio out, gain select, and amplifier shutdown |

# | \*\*VGA Port\*\* | Onboard DB15 | \*\*Chladni Pattern Output:\*\* Displays nodal sand accumulation (dark) vs. high-amplitude vibration (bright) |

# 

# \---

# 

# \## UART Serial Terminal Setup (Custom Frequency Mode)

# 

# 1\. Flip the mode switch (\*\*`SW0`\*\*) \*\*UP (`1`)\*\* on the Basys 3.

# 2\. Open your serial terminal (e.g., PuTTY) on the Basys 3 USB COM port using these settings:

# &#x20;  \* \*\*Baud Rate:\*\* `9600`

# &#x20;  \* \*\*Data Bits:\*\* `8`

# &#x20;  \* \*\*Parity:\*\* `None`

# &#x20;  \* \*\*Stop Bits:\*\* `1`

# &#x20;  \* \*\*Flow Control:\*\* `None`

# 3\. When prompted (`Enter frequency (200 - 20000 Hz):`), type an integer frequency and press \*\*Enter\*\*:

# &#x20;  \* Valid values (`200` to `20000`) immediately update both the speaker pitch and the Chladni plate wave excitation frequency, returning `\[OK] Updated!`.

# &#x20;  \* Out-of-range inputs return `\[ERR] Range: 200 - 20000 Hz` and re-prompt without disturbing the current tone.

