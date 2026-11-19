library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vgaChladniDisplay is
    generic (
        gridAddressBits : integer := 6  -- Matches 64x64 grid from waveChladniSolver
    );
    port (
        systemClock     : in  std_logic; -- 100 MHz system clock
        pixelEnable     : in  std_logic; -- 25 MHz 1-cycle pixel enable
        syncReset       : in  std_logic; -- Synchronous active-high reset
        gridX           : out unsigned(gridAddressBits - 1 downto 0);
        gridY           : out unsigned(gridAddressBits - 1 downto 0);
        sandAmplitude   : in  unsigned(15 downto 0);
        sandThreshold   : in  unsigned(15 downto 0) := to_unsigned(6200, 16);
        vgaHsync        : out std_logic;
        vgaVsync        : out std_logic;
        vgaRed          : out std_logic_vector(3 downto 0);
        vgaGreen        : out std_logic_vector(3 downto 0);
        vgaBlue         : out std_logic_vector(3 downto 0)
    );
end entity vgaChladniDisplay;

architecture behavioral of vgaChladniDisplay is

    constant horizontalActivePixels : integer := 640;
    constant horizontalFrontPorch   : integer := 16;
    constant horizontalSyncPulse    : integer := 96;
    constant horizontalBackPorch    : integer := 48;
    constant horizontalTotalPixels  : integer := 800;
    constant verticalActiveLines    : integer := 480;
    constant verticalFrontPorch     : integer := 10;
    constant verticalSyncPulse      : integer := 2;
    constant verticalBackPorch      : integer := 33;
    constant verticalTotalLines     : integer := 525;
    constant upscaleFactor          : integer := 7;   -- 64 cells * 7 px/cell = 448 px
    constant plateStartX            : integer := 96;  -- (640 - 448) / 2
    constant plateEndX              : integer := 544; -- 96 + 448
    constant plateStartY            : integer := 16;  -- (480 - 448) / 2
    constant plateEndY              : integer := 464; -- 16 + 448

    constant colorBlack             : std_logic_vector(11 downto 0) := x"000";
    constant colorBorder            : std_logic_vector(11 downto 0) := x"0DF";

    pure function computeHorizontalSync(pixelX : integer) return std_logic is
        constant syncStart : integer := horizontalActivePixels + horizontalFrontPorch;
        constant syncEnd   : integer := syncStart + horizontalSyncPulse;
    begin
        if (pixelX >= syncStart) and (pixelX < syncEnd) then
            return '0';
        else
            return '1';
        end if;
    end function;

    pure function computeVerticalSync(pixelY : integer) return std_logic is
        constant syncStart : integer := verticalActiveLines + verticalFrontPorch;
        constant syncEnd   : integer := syncStart + verticalSyncPulse;
    begin
        if (pixelY >= syncStart) and (pixelY < syncEnd) then
            return '0';
        else
            return '1';
        end if;
    end function;

    pure function isActiveDisplay(pixelX, pixelY : integer) return boolean is
    begin
        return (pixelX < horizontalActivePixels) and (pixelY < verticalActiveLines);
    end function;

    pure function isInsidePlate(pixelX, pixelY : integer) return boolean is
    begin
        return (pixelX >= plateStartX) and (pixelX < plateEndX) and
               (pixelY >= plateStartY) and (pixelY < plateEndY);
    end function;

    pure function isOnBorder(pixelX, pixelY : integer) return boolean is
    begin
        return ((pixelX = plateStartX - 2 or pixelX = plateEndX + 1) and
                (pixelY >= plateStartY - 2 and pixelY <= plateEndY + 1)) or
               ((pixelY = plateStartY - 2 or pixelY = plateEndY + 1) and
                (pixelX >= plateStartX - 2 and pixelX <= plateEndX + 1));
    end function;

    pure function isMacroPixelCorner(offsetX, offsetY : integer) return boolean is
        variable isHorizontalEdge : boolean;
        variable isVerticalEdge   : boolean;
    begin
        isHorizontalEdge := (offsetX = 0) or (offsetX = upscaleFactor - 1);
        isVerticalEdge   := (offsetY = 0) or (offsetY = upscaleFactor - 1);
        return isHorizontalEdge and isVerticalEdge;
    end function;

    pure function applyCornerSoftening(
        currentSand      : unsigned(15 downto 0);
        currentThreshold : unsigned(15 downto 0);
        isMacroCorner    : boolean
    ) return unsigned is
        variable quarterStep : unsigned(15 downto 0);
    begin
        quarterStep := shift_right(currentThreshold, 2);
        if isMacroCorner then
            return resize(currentSand, 17) + resize(quarterStep, 17);
        else
            return resize(currentSand, 17);
        end if;
    end function;

    pure function mapSandToHeatBand(
        shapedSandValue  : unsigned(16 downto 0);
        currentThreshold : unsigned(15 downto 0)
    ) return integer is
        variable quarterStep    : unsigned(15 downto 0);
        variable thresholdBand0 : unsigned(15 downto 0);
        variable thresholdBand1 : unsigned(15 downto 0);
        variable thresholdBand2 : unsigned(15 downto 0);
        variable thresholdBand3 : unsigned(15 downto 0);
        variable thresholdBand4 : unsigned(15 downto 0);
        variable thresholdBand5 : unsigned(15 downto 0);
        variable thresholdBand6 : unsigned(15 downto 0);
    begin
        quarterStep    := shift_right(currentThreshold, 2);
        thresholdBand0 := quarterStep;
        thresholdBand1 := shift_right(currentThreshold, 1);
        thresholdBand2 := thresholdBand1 + quarterStep;
        thresholdBand3 := currentThreshold;
        thresholdBand4 := currentThreshold + shift_right(currentThreshold, 1);
        thresholdBand5 := shift_left(currentThreshold, 1);
        thresholdBand6 := thresholdBand5 + currentThreshold;

        if shapedSandValue < thresholdBand0 then
            return 0;
        elsif shapedSandValue < thresholdBand1 then
            return 1;
        elsif shapedSandValue < thresholdBand2 then
            return 2;
        elsif shapedSandValue < thresholdBand3 then
            return 3;
        elsif shapedSandValue < thresholdBand4 then
            return 4;
        elsif shapedSandValue < thresholdBand5 then
            return 5;
        elsif shapedSandValue < thresholdBand6 then
            return 6;
        else
            return 7;
        end if;
    end function;

    -- Look up the 12-bit RGB color for a given heat band, colors in order are
    -- Blinding White-Cyan Core
    -- Blazing Electric Cyan
    -- Neon Cerulean-Cyan
    -- Pure Electric Azure
    -- Deep Saturated Cobalt
    -- Dark Ultramarine
    -- Faint Midnight Indigo
    -- Pure Obsidian Black 
    pure function heatBandToRgb(heatBand : integer range 0 to 7) return std_logic_vector is
    begin
        case heatBand is
            when 0 =>
                return x"EFF"; 
            when 1 =>
                return x"3FF"; 
            when 2 =>
                return x"0BF"; 
            when 3 =>
                return x"07F"; 
            when 4 =>
                return x"03D"; 
            when 5 =>
                return x"018"; 
            when 6 =>
                return x"003"; 
            when others =>
                return colorBlack; 
        end case;
    end function;

    pure function shadeChladniPixel(
        currentSand      : unsigned(15 downto 0);
        currentThreshold : unsigned(15 downto 0);
        isMacroCorner    : boolean
    ) return std_logic_vector is
        variable shapedSandValue : unsigned(16 downto 0);
        variable selectedBand    : integer range 0 to 7;
    begin
        shapedSandValue := applyCornerSoftening(currentSand, currentThreshold, isMacroCorner);
        selectedBand    := mapSandToHeatBand(shapedSandValue, currentThreshold);
        return heatBandToRgb(selectedBand);
    end function;

    pure function resolveScreenPixel(
        pixelX           : integer;
        pixelY           : integer;
        offsetX          : integer;
        offsetY          : integer;
        currentSand      : unsigned(15 downto 0);
        currentThreshold : unsigned(15 downto 0)
    ) return std_logic_vector is
        variable isMacroCorner : boolean;
    begin
        if not isActiveDisplay(pixelX, pixelY) then
            return colorBlack;
        elsif isInsidePlate(pixelX, pixelY) then
            isMacroCorner := isMacroPixelCorner(offsetX, offsetY);
            return shadeChladniPixel(currentSand, currentThreshold, isMacroCorner);
        elsif isOnBorder(pixelX, pixelY) then
            return colorBorder;
        else
            return colorBlack;
        end if;
    end function;

    signal horizontalCounter : integer range 0 to horizontalTotalPixels - 1 := 0;
    signal verticalCounter   : integer range 0 to verticalTotalLines - 1    := 0;
    signal gridXCounter      : unsigned(gridAddressBits - 1 downto 0) := (others => '0');
    signal gridYCounter      : unsigned(gridAddressBits - 1 downto 0) := (others => '0');
    signal subPixelX         : integer range 0 to upscaleFactor - 1 := 0;
    signal subPixelY         : integer range 0 to upscaleFactor - 1 := 0;

begin
    gridX <= gridXCounter;
    gridY <= gridYCounter;

    process(systemClock)

        procedure resetDisplayState is
        begin
            horizontalCounter <= 0;
            verticalCounter   <= 0;
            gridXCounter      <= (others => '0');
            gridYCounter      <= (others => '0');
            subPixelX         <= 0;
            subPixelY         <= 0;
            vgaHsync          <= '1';
            vgaVsync          <= '1';
            vgaRed            <= (others => '0');
            vgaGreen          <= (others => '0');
            vgaBlue           <= (others => '0');
        end procedure;

        procedure advanceRasterCounters is
        begin
            if horizontalCounter = horizontalTotalPixels - 1 then
                horizontalCounter <= 0;
                if verticalCounter = verticalTotalLines - 1 then
                    verticalCounter <= 0;
                else
                    verticalCounter <= verticalCounter + 1;
                end if;
            else
                horizontalCounter <= horizontalCounter + 1;
            end if;

            vgaHsync <= computeHorizontalSync(horizontalCounter);
            vgaVsync <= computeVerticalSync(verticalCounter);
        end procedure;

        procedure advanceUpscalerCounters is
        begin
            if horizontalCounter = horizontalTotalPixels - 1 then
                if (verticalCounter >= plateStartY) and (verticalCounter < plateEndY - 1) then
                    if subPixelY = upscaleFactor - 1 then
                        subPixelY    <= 0;
                        gridYCounter <= gridYCounter + 1;
                    else
                        subPixelY <= subPixelY + 1;
                    end if;
                else
                    subPixelY    <= 0;
                    gridYCounter <= (others => '0');
                end if;
            end if;

            if (horizontalCounter >= plateStartX - 1) and (horizontalCounter < plateEndX - 1) then
                if subPixelX = upscaleFactor - 1 then
                    subPixelX    <= 0;
                    gridXCounter <= gridXCounter + 1;
                else
                    subPixelX <= subPixelX + 1;
                end if;
            else
                subPixelX    <= 0;
                gridXCounter <= (others => '0');
            end if;
        end procedure;

        procedure updateVgaOutputs is
            variable outputColor : std_logic_vector(11 downto 0);
        begin
            outputColor := resolveScreenPixel(
                horizontalCounter,
                verticalCounter,
                subPixelX,
                subPixelY,
                sandAmplitude,
                sandThreshold
            );

            vgaRed   <= outputColor(11 downto 8);
            vgaGreen <= outputColor(7 downto 4);
            vgaBlue  <= outputColor(3 downto 0);
        end procedure;

    begin
        if rising_edge(systemClock) then
            if syncReset = '1' then
                resetDisplayState;
            elsif pixelEnable = '1' then
                -- Move screen pixel counters and set sync signals
                advanceRasterCounters;
                -- Scale 64x64 grid up by 7x and fetch next cell early
                advanceUpscalerCounters;
                -- Pick pixel color and send to VGA output
                updateVgaOutputs;
            end if;
        end if;
    end process;

end architecture behavioral;