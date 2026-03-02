//+------------------------------------------------------------------+
//|                                     SZA_EMA_TripleTrend_H1.mq5   |
//|                        Copyright 2026, SZA Trading Systems        |
//|                                                                    |
//|  EA Name : SZA_EMA_TripleTrend_H1                                 |
//|  Core    : Trend filter EMA(9/21/55) on H1. Enter when price is   |
//|            clearly above all EMAs (bull) or below (bear). SL at   |
//|            last confirmed swing. TP at structure or fixed RR.      |
//|  Design  : Multi-symbol, hedging+netting safe, CTrade-based.      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, SZA Trading Systems"
#property link      ""
#property version   "1.00"
#property strict
#property description "EMA Triple-Trend H1 Expert Advisor"
#property description "Trend-following system using EMA 9/21/55 alignment"
#property description "Multi-symbol capable with strict risk controls"

//--- includes
#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\DealInfo.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                      |
//+------------------------------------------------------------------+

//--- Entry mode: how we trigger trades
enum ENUM_ENTRY_MODE
  {
   ENTRY_CLOSE_CONFIRM = 0,   // Close Confirm – enter on next bar after qualifying close
   ENTRY_BREAK_RETEST  = 1    // Break & Retest – require retest of EMA before entry
  };

//--- Swing detection mode
enum ENUM_SWING_MODE
  {
   SWING_FRACTAL = 0,   // Fractal-style (L=R bars each side)
   SWING_LR      = 1    // Custom L/R swing algorithm
  };

//--- Take-profit mode
enum ENUM_TP_MODE
  {
   TP_RR             = 0,   // Fixed risk-reward ratio
   TP_NEXT_STRUCTURE = 1    // Next structure level (fallback to RR)
  };

//--- Risk sizing mode
enum ENUM_RISK_MODE
  {
   RISK_PERCENT  = 0,   // Risk as % of account balance
   RISK_CURRENCY = 1    // Risk as fixed currency amount
  };

//--- Log verbosity
enum ENUM_LOG_LEVEL
  {
   LOG_SILENT  = 0,   // No logs
   LOG_MINIMAL = 1,   // Errors and trades only
   LOG_NORMAL  = 2,   // Signals and trades
   LOG_VERBOSE = 3    // Everything (debug)
  };

//--- Trend state
enum ENUM_TREND_STATE
  {
   TREND_BULL    = 1,
   TREND_BEAR    = -1,
   TREND_NEUTRAL = 0
  };

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+

//--- Symbol & identification
input string   InpSymbolsCSV        = "";              // Symbols CSV (empty = chart symbol)
input int      InpMagicNumberBase   = 202600;          // Magic number base (each symbol +index)

//--- Timeframe (fixed to H1 for signals)
input ENUM_TIMEFRAMES InpTradeTimeframe = PERIOD_H1;   // Trading timeframe (fixed H1)

//--- EMA periods
input int      InpEMA_Fast          = 9;               // EMA Fast period
input int      InpEMA_Mid           = 21;              // EMA Mid period
input int      InpEMA_Slow          = 55;              // EMA Slow period

//--- Entry mode
input ENUM_ENTRY_MODE InpEntryMode  = ENTRY_CLOSE_CONFIRM; // Entry mode

//--- Swing configuration
input ENUM_SWING_MODE InpSwingMode  = SWING_LR;        // Swing detection mode
input int      InpSwingL            = 2;               // Swing left bars
input int      InpSwingR            = 2;               // Swing right bars
input int      InpSwingLookback     = 200;             // Swing lookback bars
input int      InpSL_Buffer_Points  = 50;              // SL buffer (points)

//--- Take profit
input ENUM_TP_MODE InpTP_Mode       = TP_RR;           // TP mode
input double   InpRR_Multiple       = 2.0;             // Risk-reward multiple
input int      InpStructureLookback = 100;             // Structure lookback bars

//--- Risk
input ENUM_RISK_MODE InpRiskMode    = RISK_PERCENT;    // Risk mode
input double   InpRiskPercent       = 0.5;             // Risk percent of balance
input double   InpRiskCurrency      = 50.0;            // Risk in account currency
input int      InpMaxSpreadPoints   = 30;              // Max spread (points), 0=off

//--- Position management
input int      InpMaxTradesTotal    = 5;               // Max open trades total
input bool     InpOnePerSymbol      = true;            // One position per symbol
input bool     InpAllowFlip         = false;           // Allow position flip
input int      InpCooldownBars      = 3;               // Cooldown bars after trade close

//--- Break-even
input bool     InpBE_Enable         = false;           // Enable break-even
input double   InpBE_Trigger_R      = 1.0;             // BE trigger (multiples of risk)
input int      InpBE_Offset_Points  = 10;              // BE offset above entry (points)

//--- Trailing stop
input bool     InpTrail_Enable      = false;           // Enable trailing stop
input double   InpTrail_Trigger_R   = 1.0;             // Trail trigger (multiples of risk)
input int      InpTrail_ATR_Period  = 14;              // Trail ATR period
input double   InpTrail_ATR_Mult    = 1.5;             // Trail ATR multiplier

//--- Daily loss limit
input double   InpDailyLossLimit    = 0.0;             // Daily loss limit (currency, 0=off)
input double   InpMaxEquityDD_Pct   = 0.0;             // Max equity drawdown % (0=off)

//--- Session & news filters
input string   InpNoTradeDates      = "";              // No-trade dates (YYYY-MM-DD;...)
input string   InpNoTradeHours      = "";              // No-trade hours (HH-HH;...)

//--- Self-test / debug
input bool     InpSelfTest          = false;           // Self-test mode (log only, no trades)

//--- Log
input ENUM_LOG_LEVEL InpLogLevel    = LOG_NORMAL;      // Log verbosity

//+------------------------------------------------------------------+
//| Constants                                                         |
//+------------------------------------------------------------------+
#define MAX_SYMBOLS       20       // maximum symbols we support
#define DASHBOARD_X       10       // dashboard X offset
#define DASHBOARD_Y       30       // dashboard Y offset
#define DASH_LINE_HEIGHT  18       // pixel height per line
#define DASH_FONT_SIZE    9        // dashboard font size
#define DASH_PREFIX       "SZA_DASH_"  // object prefix for dashboard

//+------------------------------------------------------------------+
//| Per-symbol state structure                                        |
//+------------------------------------------------------------------+
struct SymbolState
  {
   string            symbol;           // symbol name
   int               magicNumber;      // unique magic per symbol
   int               handleEMA9;       // EMA fast handle
   int               handleEMA21;      // EMA mid handle
   int               handleEMA55;      // EMA slow handle
   int               handleATR;        // ATR handle (for trailing)
   datetime          lastBarTime;      // last processed H1 bar time
   datetime          lastTradeClose;   // when last trade closed (for cooldown)
   int               barsSinceClose;   // bars since last trade closed
   ENUM_TREND_STATE  trendState;       // current trend state
   datetime          lastSignalTime;   // time of last signal detection
   bool              initialized;      // successfully initialized
  };

//+------------------------------------------------------------------+
//| Global variables                                                  |
//+------------------------------------------------------------------+
SymbolState  g_states[];                // array of per-symbol states
int          g_symbolCount = 0;         // number of symbols
CTrade       g_trade;                   // trade object
double       g_dailyStartBalance = 0;   // balance at start of day
datetime     g_dailyResetDate = 0;      // date of last daily reset
bool         g_dailyLimitHit = false;   // daily loss limit flag
bool         g_equityDDHit = false;     // equity DD flag
double       g_peakEquity = 0;          // peak equity for DD calculation

//--- No-trade date/hour arrays (parsed from inputs)
datetime     g_noTradeDates[];          // parsed no-trade dates
int          g_noTradeHourStart[];      // no-trade hour ranges start
int          g_noTradeHourEnd[];        // no-trade hour ranges end

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Parse symbol list
   string symbols[];
   if(StringLen(InpSymbolsCSV) > 0)
     {
      int count = StringSplit(InpSymbolsCSV, ',', symbols);
      if(count <= 0)
        {
         PrintError("Failed to parse SymbolsCSV input");
         return INIT_FAILED;
        }
      //--- trim whitespace
      for(int i = 0; i < count; i++)
        {
         StringTrimLeft(symbols[i]);
         StringTrimRight(symbols[i]);
        }
     }
   else
     {
      ArrayResize(symbols, 1);
      symbols[0] = _Symbol;
     }

   g_symbolCount = MathMin(ArraySize(symbols), MAX_SYMBOLS);
   ArrayResize(g_states, g_symbolCount);

   //--- Initialize each symbol
   for(int i = 0; i < g_symbolCount; i++)
     {
      g_states[i].symbol        = symbols[i];
      g_states[i].magicNumber   = InpMagicNumberBase + i;
      g_states[i].lastBarTime   = 0;
      g_states[i].lastTradeClose = 0;
      g_states[i].barsSinceClose = InpCooldownBars + 1; // allow trading immediately
      g_states[i].trendState    = TREND_NEUTRAL;
      g_states[i].lastSignalTime = 0;
      g_states[i].initialized   = false;

      //--- Verify symbol exists in Market Watch
      if(!SymbolSelect(g_states[i].symbol, true))
        {
         PrintFormat("WARNING: Symbol %s not available, skipping", g_states[i].symbol);
         continue;
        }

      //--- Create indicator handles
      g_states[i].handleEMA9 = iMA(g_states[i].symbol, InpTradeTimeframe,
                                    InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      g_states[i].handleEMA21 = iMA(g_states[i].symbol, InpTradeTimeframe,
                                     InpEMA_Mid, 0, MODE_EMA, PRICE_CLOSE);
      g_states[i].handleEMA55 = iMA(g_states[i].symbol, InpTradeTimeframe,
                                     InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
      g_states[i].handleATR = iATR(g_states[i].symbol, InpTradeTimeframe,
                                    InpTrail_ATR_Period);

      if(g_states[i].handleEMA9 == INVALID_HANDLE ||
         g_states[i].handleEMA21 == INVALID_HANDLE ||
         g_states[i].handleEMA55 == INVALID_HANDLE ||
         g_states[i].handleATR == INVALID_HANDLE)
        {
         PrintFormat("ERROR: Failed to create indicator handles for %s", g_states[i].symbol);
         continue;
        }

      g_states[i].initialized = true;
      PrintLog(LOG_NORMAL, StringFormat("Initialized symbol %s (magic=%d)",
               g_states[i].symbol, g_states[i].magicNumber));
     }

   //--- Parse no-trade dates
   ParseNoTradeDates(InpNoTradeDates);

   //--- Parse no-trade hours
   ParseNoTradeHours(InpNoTradeHours);

   //--- Set trade object defaults
   g_trade.SetExpertMagicNumber(InpMagicNumberBase);
   g_trade.SetDeviationInPoints(10);
   g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   g_trade.SetMarginMode();

   //--- Initialize daily tracking
   g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt;
   TimeCurrent(dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   g_dailyResetDate = StructToTime(dt);
   g_dailyLimitHit = false;
   g_equityDDHit = false;
   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   //--- Start timer for dashboard + multi-symbol checks (2 seconds)
   EventSetTimer(2);

   //--- Create dashboard
   CreateDashboard();

   PrintLog(LOG_NORMAL, StringFormat("SZA_EMA_TripleTrend_H1 initialized. Symbols: %d, Mode: %s",
            g_symbolCount, EnumToString(InpEntryMode)));

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   //--- Release indicator handles
   for(int i = 0; i < g_symbolCount; i++)
     {
      if(g_states[i].handleEMA9  != INVALID_HANDLE) IndicatorRelease(g_states[i].handleEMA9);
      if(g_states[i].handleEMA21 != INVALID_HANDLE) IndicatorRelease(g_states[i].handleEMA21);
      if(g_states[i].handleEMA55 != INVALID_HANDLE) IndicatorRelease(g_states[i].handleEMA55);
      if(g_states[i].handleATR   != INVALID_HANDLE) IndicatorRelease(g_states[i].handleATR);
     }

   //--- Kill timer
   EventKillTimer();

   //--- Remove dashboard objects
   ObjectsDeleteAll(0, DASH_PREFIX);

   PrintLog(LOG_NORMAL, "SZA_EMA_TripleTrend_H1 deinitialized. Reason: " +
            IntegerToString(reason));
  }

//+------------------------------------------------------------------+
//| Expert tick function (lightweight)                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Only process the chart symbol on tick for responsiveness
   //--- Multi-symbol processing happens in OnTimer
   for(int i = 0; i < g_symbolCount; i++)
     {
      if(g_states[i].symbol == _Symbol && g_states[i].initialized)
        {
         ProcessSymbol(i);
         break;
        }
     }
  }

//+------------------------------------------------------------------+
//| Timer function – multi-symbol processing + dashboard update       |
//+------------------------------------------------------------------+
void OnTimer()
  {
   //--- Update daily tracking
   CheckDailyReset();

   //--- Update equity DD tracking
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity)
      g_peakEquity = equity;

   //--- Process all symbols
   for(int i = 0; i < g_symbolCount; i++)
     {
      if(!g_states[i].initialized)
         continue;
      ProcessSymbol(i);
     }

   //--- Manage open positions (trailing, break-even)
   ManageOpenPositions();

   //--- Update dashboard
   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Core symbol processing – called per symbol per new bar            |
//+------------------------------------------------------------------+
void ProcessSymbol(int idx)
  {
   if(idx < 0 || idx >= g_symbolCount)
      return;

   string sym = g_states[idx].symbol;

   //--- New bar detection for this symbol on H1
   datetime barTimes[];
   if(CopyTime(sym, InpTradeTimeframe, 0, 1, barTimes) != 1)
      return;

   if(barTimes[0] == g_states[idx].lastBarTime)
      return; // no new bar

   g_states[idx].lastBarTime = barTimes[0];

   //--- Increment cooldown counter
   g_states[idx].barsSinceClose++;

   //--- Fetch indicator values for bar[1] (last closed bar)
   double ema9[], ema21[], ema55[];
   if(CopyBuffer(g_states[idx].handleEMA9,  0, 1, 1, ema9)  != 1 ||
      CopyBuffer(g_states[idx].handleEMA21, 0, 1, 1, ema21) != 1 ||
      CopyBuffer(g_states[idx].handleEMA55, 0, 1, 1, ema55) != 1)
     {
      PrintLog(LOG_MINIMAL, StringFormat("Failed to copy EMA buffers for %s", sym));
      return;
     }

   //--- Fetch close price of bar[1]
   double closes[];
   if(CopyClose(sym, InpTradeTimeframe, 1, 1, closes) != 1)
      return;

   double close1 = closes[0];

   //--- Determine trend state
   ENUM_TREND_STATE trend = TREND_NEUTRAL;
   if(close1 > ema9[0] && close1 > ema21[0] && close1 > ema55[0])
      trend = TREND_BULL;
   else if(close1 < ema9[0] && close1 < ema21[0] && close1 < ema55[0])
      trend = TREND_BEAR;

   g_states[idx].trendState = trend;

   //--- Self-test logging
   if(InpSelfTest)
     {
      PrintFormat("[SELFTEST] %s | Close[1]=%.5f | EMA9=%.5f EMA21=%.5f EMA55=%.5f | Trend=%s",
                  sym, close1, ema9[0], ema21[0], ema55[0], TrendToString(trend));
      LogSwingPoints(idx);
      return; // no trading in self-test mode
     }

   //--- Check if trading is allowed
   if(!IsTradingAllowed(idx))
      return;

   //--- No trend, no trade
   if(trend == TREND_NEUTRAL)
      return;

   //--- Entry logic
   if(InpEntryMode == ENTRY_CLOSE_CONFIRM)
      EvaluateCloseConfirmEntry(idx, trend, close1, ema9[0], ema21[0], ema55[0]);
   else
      EvaluateBreakRetestEntry(idx, trend, close1, ema9[0], ema21[0], ema55[0]);
  }

//+------------------------------------------------------------------+
//| Close-Confirm entry logic                                         |
//| Enter at market when bar[1] closed above/below all EMAs           |
//+------------------------------------------------------------------+
void EvaluateCloseConfirmEntry(int idx, ENUM_TREND_STATE trend,
                                double close1, double ema9, double ema21, double ema55)
  {
   string sym = g_states[idx].symbol;

   //--- Check if we already have a position in this direction
   if(InpOnePerSymbol && HasPosition(sym, g_states[idx].magicNumber))
     {
      //--- If allow flip and we have opposite direction, close it first
      if(InpAllowFlip)
        {
         ENUM_POSITION_TYPE existingType = GetPositionType(sym, g_states[idx].magicNumber);
         if((trend == TREND_BULL && existingType == POSITION_TYPE_SELL) ||
            (trend == TREND_BEAR && existingType == POSITION_TYPE_BUY))
           {
            ClosePositions(sym, g_states[idx].magicNumber);
            PrintLog(LOG_NORMAL, StringFormat("Flipping position on %s, trend=%s",
                     sym, TrendToString(trend)));
           }
         else
            return; // same direction, already have position
        }
      else
         return; // one position per symbol, already have one
     }

   g_states[idx].lastSignalTime = TimeCurrent();
   ExecuteEntry(idx, trend);
  }

//+------------------------------------------------------------------+
//| Break-Retest entry logic                                          |
//| Require close above/below EMAs AND bar[1] retested EMA21          |
//+------------------------------------------------------------------+
void EvaluateBreakRetestEntry(int idx, ENUM_TREND_STATE trend,
                               double close1, double ema9, double ema21, double ema55)
  {
   string sym = g_states[idx].symbol;

   //--- Check if we already have a position
   if(InpOnePerSymbol && HasPosition(sym, g_states[idx].magicNumber))
     {
      if(InpAllowFlip)
        {
         ENUM_POSITION_TYPE existingType = GetPositionType(sym, g_states[idx].magicNumber);
         if((trend == TREND_BULL && existingType == POSITION_TYPE_SELL) ||
            (trend == TREND_BEAR && existingType == POSITION_TYPE_BUY))
           {
            ClosePositions(sym, g_states[idx].magicNumber);
           }
         else
            return;
        }
      else
         return;
     }

   //--- For break & retest, check bar[1] low (buy) or high (sell) touched EMA21
   //--- This means the bar retested the EMA and then closed beyond all EMAs
   double lows[], highs[];
   if(CopyLow(sym, InpTradeTimeframe, 1, 1, lows) != 1 ||
      CopyHigh(sym, InpTradeTimeframe, 1, 1, highs) != 1)
      return;

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   double retestBuffer = 5.0 * point; // small tolerance

   if(trend == TREND_BULL)
     {
      //--- Bar[1] low should have touched or gone below EMA21 (retest), then closed above all
      if(lows[0] > ema21 + retestBuffer)
         return; // no retest occurred
     }
   else if(trend == TREND_BEAR)
     {
      //--- Bar[1] high should have touched or gone above EMA21 (retest), then closed below all
      if(highs[0] < ema21 - retestBuffer)
         return; // no retest occurred
     }

   g_states[idx].lastSignalTime = TimeCurrent();
   ExecuteEntry(idx, trend);
  }

//+------------------------------------------------------------------+
//| Execute trade entry                                               |
//+------------------------------------------------------------------+
void ExecuteEntry(int idx, ENUM_TREND_STATE trend)
  {
   string sym = g_states[idx].symbol;
   int magic = g_states[idx].magicNumber;
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   //--- Get entry price
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);

   //--- Spread check
   if(InpMaxSpreadPoints > 0)
     {
      double spreadPts = (ask - bid) / point;
      if(spreadPts > InpMaxSpreadPoints)
        {
         PrintLog(LOG_NORMAL, StringFormat("Spread too wide on %s: %.1f > %d pts",
                  sym, spreadPts, InpMaxSpreadPoints));
         return;
        }
     }

   //--- Calculate SL
   double slPrice = 0;
   double swingPrice = 0;
   datetime swingTime = 0;

   if(trend == TREND_BULL)
     {
      if(!FindLastSwingLow(idx, swingPrice, swingTime))
        {
         PrintLog(LOG_NORMAL, StringFormat("No swing low found for %s, skipping BUY", sym));
         return;
        }
      slPrice = NormalizeDouble(swingPrice - InpSL_Buffer_Points * point, digits);
      double entry = ask;

      //--- Validate SL is below entry
      if(slPrice >= entry)
        {
         PrintLog(LOG_NORMAL, StringFormat("SL (%.5f) >= entry (%.5f) for BUY on %s, skipping",
                  slPrice, entry, sym));
         return;
        }

      //--- Calculate TP
      double tpPrice = ComputeTP(idx, entry, slPrice, TREND_BULL);

      //--- Validate stops
      if(!ValidateStops(sym, entry, slPrice, tpPrice, ORDER_TYPE_BUY))
        {
         PrintLog(LOG_NORMAL, StringFormat("Stops validation failed for BUY on %s", sym));
         return;
        }

      //--- Calculate lot size
      double lots = ComputeLotByRisk(sym, entry, slPrice);
      if(lots <= 0)
        {
         PrintLog(LOG_MINIMAL, StringFormat("Invalid lot size for BUY on %s", sym));
         return;
        }

      //--- Max trades check
      if(CountOpenTrades() >= InpMaxTradesTotal)
        {
         PrintLog(LOG_NORMAL, "Max trades reached, skipping entry");
         return;
        }

      //--- Execute BUY
      g_trade.SetExpertMagicNumber(magic);
      string comment = StringFormat("SZA_BUY_%s", sym);
      if(g_trade.Buy(lots, sym, ask, slPrice, tpPrice, comment))
        {
         PrintLog(LOG_NORMAL, StringFormat("BUY %s: lots=%.2f entry=%.5f sl=%.5f tp=%.5f",
                  sym, lots, ask, slPrice, tpPrice));
        }
      else
        {
         PrintLog(LOG_MINIMAL, StringFormat("BUY FAILED %s: error=%d, retcode=%u",
                  sym, GetLastError(), g_trade.ResultRetcode()));
        }
     }
   else if(trend == TREND_BEAR)
     {
      if(!FindLastSwingHigh(idx, swingPrice, swingTime))
        {
         PrintLog(LOG_NORMAL, StringFormat("No swing high found for %s, skipping SELL", sym));
         return;
        }
      slPrice = NormalizeDouble(swingPrice + InpSL_Buffer_Points * point, digits);
      double entry = bid;

      //--- Validate SL is above entry
      if(slPrice <= entry)
        {
         PrintLog(LOG_NORMAL, StringFormat("SL (%.5f) <= entry (%.5f) for SELL on %s, skipping",
                  slPrice, entry, sym));
         return;
        }

      //--- Calculate TP
      double tpPrice = ComputeTP(idx, entry, slPrice, TREND_BEAR);

      //--- Validate stops
      if(!ValidateStops(sym, entry, slPrice, tpPrice, ORDER_TYPE_SELL))
        {
         PrintLog(LOG_NORMAL, StringFormat("Stops validation failed for SELL on %s", sym));
         return;
        }

      //--- Calculate lot size
      double lots = ComputeLotByRisk(sym, entry, slPrice);
      if(lots <= 0)
        {
         PrintLog(LOG_MINIMAL, StringFormat("Invalid lot size for SELL on %s", sym));
         return;
        }

      //--- Max trades check
      if(CountOpenTrades() >= InpMaxTradesTotal)
        {
         PrintLog(LOG_NORMAL, "Max trades reached, skipping entry");
         return;
        }

      //--- Execute SELL
      g_trade.SetExpertMagicNumber(magic);
      string comment = StringFormat("SZA_SELL_%s", sym);
      if(g_trade.Sell(lots, sym, bid, slPrice, tpPrice, comment))
        {
         PrintLog(LOG_NORMAL, StringFormat("SELL %s: lots=%.2f entry=%.5f sl=%.5f tp=%.5f",
                  sym, lots, bid, slPrice, tpPrice));
        }
      else
        {
         PrintLog(LOG_MINIMAL, StringFormat("SELL FAILED %s: error=%d, retcode=%u",
                  sym, GetLastError(), g_trade.ResultRetcode()));
        }
     }
  }

//+------------------------------------------------------------------+
//| Compute take-profit price                                         |
//+------------------------------------------------------------------+
double ComputeTP(int idx, double entry, double sl, ENUM_TREND_STATE trend)
  {
   string sym = g_states[idx].symbol;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double riskDist = MathAbs(entry - sl);

   if(InpTP_Mode == TP_RR)
     {
      //--- Fixed RR
      if(trend == TREND_BULL)
         return NormalizeDouble(entry + InpRR_Multiple * riskDist, digits);
      else
         return NormalizeDouble(entry - InpRR_Multiple * riskDist, digits);
     }

   //--- NEXT_STRUCTURE mode
   double structPrice = 0;
   datetime structTime = 0;

   if(trend == TREND_BULL)
     {
      //--- Find next swing high above entry
      if(FindStructureTarget(idx, entry, TREND_BULL, structPrice))
        {
         //--- Make sure it gives at least 1R
         if(structPrice > entry + riskDist)
            return NormalizeDouble(structPrice, digits);
        }
      //--- Fallback to RR
      return NormalizeDouble(entry + InpRR_Multiple * riskDist, digits);
     }
   else
     {
      //--- Find next swing low below entry
      if(FindStructureTarget(idx, entry, TREND_BEAR, structPrice))
        {
         if(structPrice < entry - riskDist)
            return NormalizeDouble(structPrice, digits);
        }
      //--- Fallback to RR
      return NormalizeDouble(entry - InpRR_Multiple * riskDist, digits);
     }
  }

//+------------------------------------------------------------------+
//| Find structure target (nearest swing in trade direction)          |
//+------------------------------------------------------------------+
bool FindStructureTarget(int idx, double entry, ENUM_TREND_STATE direction, double &targetPrice)
  {
   string sym = g_states[idx].symbol;
   int lookback = InpStructureLookback;

   double highs[], lows[];
   if(CopyHigh(sym, InpTradeTimeframe, 1, lookback, highs) != lookback ||
      CopyLow(sym, InpTradeTimeframe, 1, lookback, lows) != lookback)
      return false;

   int swL = InpSwingL;
   int swR = InpSwingR;
   double bestPrice = 0;
   bool found = false;

   if(direction == TREND_BULL)
     {
      //--- Find swing highs above entry, pick the nearest one
      double nearest = DBL_MAX;
      for(int i = lookback - 1 - swR; i >= swL; i--)
        {
         if(IsSwingHigh(highs, i, swL, swR, lookback))
           {
            if(highs[i] > entry && highs[i] < nearest)
              {
               nearest = highs[i];
               found = true;
              }
           }
        }
      if(found)
         targetPrice = nearest;
     }
   else
     {
      //--- Find swing lows below entry, pick the nearest one
      double nearest = 0;
      for(int i = lookback - 1 - swR; i >= swL; i--)
        {
         if(IsSwingLow(lows, i, swL, swR, lookback))
           {
            if(lows[i] < entry && (nearest == 0 || lows[i] > nearest))
              {
               nearest = lows[i];
               found = true;
              }
           }
        }
      if(found)
         targetPrice = nearest;
     }

   return found;
  }

//+------------------------------------------------------------------+
//| Check if trading is allowed for a symbol                          |
//+------------------------------------------------------------------+
bool IsTradingAllowed(int idx)
  {
   //--- Global trading permission
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      PrintLog(LOG_VERBOSE, "Trading not allowed by terminal");
      return false;
     }

   //--- Daily loss limit
   if(g_dailyLimitHit)
     {
      PrintLog(LOG_VERBOSE, "Daily loss limit reached");
      return false;
     }

   //--- Equity drawdown
   if(InpMaxEquityDD_Pct > 0)
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(g_peakEquity > 0)
        {
         double ddPct = (g_peakEquity - equity) / g_peakEquity * 100.0;
         if(ddPct >= InpMaxEquityDD_Pct)
           {
            g_equityDDHit = true;
            PrintLog(LOG_MINIMAL, StringFormat("Equity DD %.2f%% >= limit %.2f%%",
                     ddPct, InpMaxEquityDD_Pct));
            return false;
           }
        }
     }

   if(g_equityDDHit)
      return false;

   //--- Cooldown check
   if(g_states[idx].barsSinceClose < InpCooldownBars)
     {
      PrintLog(LOG_VERBOSE, StringFormat("Cooldown active for %s: %d/%d bars",
               g_states[idx].symbol, g_states[idx].barsSinceClose, InpCooldownBars));
      return false;
     }

   //--- No-trade dates
   if(IsNoTradeDate())
      return false;

   //--- No-trade hours
   if(IsNoTradeHour())
      return false;

   //--- Check daily loss limit (currency)
   if(InpDailyLossLimit > 0)
     {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double dailyPL = currentBalance - g_dailyStartBalance;
      if(dailyPL <= -InpDailyLossLimit)
        {
         g_dailyLimitHit = true;
         PrintLog(LOG_MINIMAL, StringFormat("Daily loss limit hit: PL=%.2f, Limit=%.2f",
                  dailyPL, InpDailyLossLimit));
         return false;
        }
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Find the last confirmed swing low for a symbol                    |
//+------------------------------------------------------------------+
bool FindLastSwingLow(int idx, double &price, datetime &time)
  {
   string sym = g_states[idx].symbol;
   int lookback = InpSwingLookback;
   int swL = InpSwingL;
   int swR = InpSwingR;

   double lows[];
   datetime times[];
   if(CopyLow(sym, InpTradeTimeframe, 1, lookback, lows) != lookback ||
      CopyTime(sym, InpTradeTimeframe, 1, lookback, times) != lookback)
     {
      PrintLog(LOG_MINIMAL, StringFormat("Failed to copy data for swing low on %s", sym));
      return false;
     }

   //--- Search from most recent confirmed bar backward
   //--- A swing at index i is confirmed if there are at least swR bars after it
   //--- Since we copy from bar[1], index (lookback-1) is bar[1], index 0 is bar[lookback]
   //--- We need i such that i+swR < lookback (i.e. there are swR bars to the right)
   for(int i = lookback - 1 - swR; i >= swL; i--)
     {
      if(IsSwingLow(lows, i, swL, swR, lookback))
        {
         price = lows[i];
         time = times[i];
         return true;
        }
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Find the last confirmed swing high for a symbol                   |
//+------------------------------------------------------------------+
bool FindLastSwingHigh(int idx, double &price, datetime &time)
  {
   string sym = g_states[idx].symbol;
   int lookback = InpSwingLookback;
   int swL = InpSwingL;
   int swR = InpSwingR;

   double highs[];
   datetime times[];
   if(CopyHigh(sym, InpTradeTimeframe, 1, lookback, highs) != lookback ||
      CopyTime(sym, InpTradeTimeframe, 1, lookback, times) != lookback)
     {
      PrintLog(LOG_MINIMAL, StringFormat("Failed to copy data for swing high on %s", sym));
      return false;
     }

   for(int i = lookback - 1 - swR; i >= swL; i--)
     {
      if(IsSwingHigh(highs, i, swL, swR, lookback))
        {
         price = highs[i];
         time = times[i];
         return true;
        }
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Check if a bar is a swing low (minimum of surrounding L/R bars)   |
//+------------------------------------------------------------------+
bool IsSwingLow(const double &lows[], int i, int L, int R, int size)
  {
   if(i < L || i + R >= size)
      return false;

   for(int j = 1; j <= L; j++)
     {
      if(lows[i] > lows[i - j])
         return false;
     }
   for(int j = 1; j <= R; j++)
     {
      if(lows[i] > lows[i + j])
         return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Check if a bar is a swing high (maximum of surrounding L/R bars)  |
//+------------------------------------------------------------------+
bool IsSwingHigh(const double &highs[], int i, int L, int R, int size)
  {
   if(i < L || i + R >= size)
      return false;

   for(int j = 1; j <= L; j++)
     {
      if(highs[i] < highs[i - j])
         return false;
     }
   for(int j = 1; j <= R; j++)
     {
      if(highs[i] < highs[i + j])
         return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Compute lot size based on risk                                    |
//+------------------------------------------------------------------+
double ComputeLotByRisk(string sym, double entry, double sl)
  {
   double riskAmount = 0;

   if(InpRiskMode == RISK_PERCENT)
      riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   else
      riskAmount = InpRiskCurrency;

   if(riskAmount <= 0)
      return 0;

   double slDistance = MathAbs(entry - sl);
   if(slDistance <= 0)
      return 0;

   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0 || tickValue <= 0)
     {
      PrintLog(LOG_MINIMAL, StringFormat("Invalid tick info for %s: size=%.10f value=%.10f",
               sym, tickSize, tickValue));
      return 0;
     }

   //--- lots = riskAmount / (slDistance / tickSize * tickValue)
   double slTicks = slDistance / tickSize;
   double lossPerLot = slTicks * tickValue;
   if(lossPerLot <= 0)
      return 0;

   double lots = riskAmount / lossPerLot;

   //--- Normalize to broker constraints
   lots = NormalizeLots(sym, lots);

   return lots;
  }

//+------------------------------------------------------------------+
//| Normalize lot size to broker constraints                          |
//+------------------------------------------------------------------+
double NormalizeLots(string sym, double lots)
  {
   double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0)
      lotStep = 0.01;

   //--- Round down to step
   lots = MathFloor(lots / lotStep) * lotStep;

   //--- Clamp to min/max
   if(lots < minLot)
      return 0; // can't afford minimum lot
   if(lots > maxLot)
      lots = maxLot;

   //--- Final normalize to avoid floating point issues
   int lotDigits = (int)MathCeil(-MathLog10(lotStep));
   lots = NormalizeDouble(lots, lotDigits);

   return lots;
  }

//+------------------------------------------------------------------+
//| Validate SL/TP against broker stops level and freeze level        |
//+------------------------------------------------------------------+
bool ValidateStops(string sym, double entry, double sl, double tp, ENUM_ORDER_TYPE orderType)
  {
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int stopsLevel = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double minDistance = stopsLevel * point;

   //--- Check SL distance
   double slDist = MathAbs(entry - sl);
   if(slDist < minDistance)
     {
      PrintLog(LOG_NORMAL, StringFormat("SL too close on %s: %.5f < min %.5f",
               sym, slDist, minDistance));
      return false;
     }

   //--- Check TP distance
   if(tp > 0)
     {
      double tpDist = MathAbs(entry - tp);
      if(tpDist < minDistance)
        {
         PrintLog(LOG_NORMAL, StringFormat("TP too close on %s: %.5f < min %.5f",
                  sym, tpDist, minDistance));
         return false;
        }
     }

   //--- Verify SL/TP on correct side
   if(orderType == ORDER_TYPE_BUY)
     {
      if(sl >= entry)
        {
         PrintLog(LOG_NORMAL, StringFormat("SL above entry for BUY on %s", sym));
         return false;
        }
      if(tp > 0 && tp <= entry)
        {
         PrintLog(LOG_NORMAL, StringFormat("TP below entry for BUY on %s", sym));
         return false;
        }
     }
   else
     {
      if(sl <= entry)
        {
         PrintLog(LOG_NORMAL, StringFormat("SL below entry for SELL on %s", sym));
         return false;
        }
      if(tp > 0 && tp >= entry)
        {
         PrintLog(LOG_NORMAL, StringFormat("TP above entry for SELL on %s", sym));
         return false;
        }
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Manage open positions (trailing stop, break-even)                 |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   for(int i = 0; i < g_symbolCount; i++)
     {
      if(!g_states[i].initialized)
         continue;

      string sym = g_states[i].symbol;
      int magic = g_states[i].magicNumber;

      //--- Iterate positions for this symbol and magic
      for(int p = PositionsTotal() - 1; p >= 0; p--)
        {
         ulong ticket = PositionGetTicket(p);
         if(ticket == 0)
            continue;

         if(PositionGetString(POSITION_SYMBOL) != sym)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic)
            continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);
         double volume    = PositionGetDouble(POSITION_VOLUME);
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
         int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
         double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);

         //--- Calculate initial risk distance (entry to original SL)
         double riskDist = MathAbs(openPrice - currentSL);
         if(riskDist <= 0)
            continue;

         //--- Current profit in price units
         double profitDist = 0;
         if(posType == POSITION_TYPE_BUY)
            profitDist = bid - openPrice;
         else
            profitDist = openPrice - ask;

         double profitR = profitDist / riskDist;

         //--- Break-even logic
         if(InpBE_Enable && profitR >= InpBE_Trigger_R)
           {
            double newSL = 0;
            if(posType == POSITION_TYPE_BUY)
               newSL = NormalizeDouble(openPrice + InpBE_Offset_Points * point, digits);
            else
               newSL = NormalizeDouble(openPrice - InpBE_Offset_Points * point, digits);

            //--- Only move SL if it improves the position
            bool shouldMove = false;
            if(posType == POSITION_TYPE_BUY && newSL > currentSL)
               shouldMove = true;
            else if(posType == POSITION_TYPE_SELL && newSL < currentSL)
               shouldMove = true;

            if(shouldMove)
              {
               g_trade.SetExpertMagicNumber(magic);
               if(g_trade.PositionModify(ticket, newSL, currentTP))
                 {
                  PrintLog(LOG_NORMAL, StringFormat("Break-even set on %s: SL=%.5f",
                           sym, newSL));
                 }
               else
                 {
                  PrintLog(LOG_MINIMAL, StringFormat("Break-even modify failed on %s: err=%d",
                           sym, GetLastError()));
                 }
               continue; // don't also trail on same tick
              }
           }

         //--- Trailing stop logic
         if(InpTrail_Enable && profitR >= InpTrail_Trigger_R)
           {
            //--- Get ATR for trailing distance
            double atr[];
            if(CopyBuffer(g_states[i].handleATR, 0, 1, 1, atr) != 1)
               continue;

            double trailDist = atr[0] * InpTrail_ATR_Mult;
            double newSL = 0;

            if(posType == POSITION_TYPE_BUY)
              {
               newSL = NormalizeDouble(bid - trailDist, digits);
               if(newSL > currentSL && newSL < bid)
                 {
                  g_trade.SetExpertMagicNumber(magic);
                  if(g_trade.PositionModify(ticket, newSL, currentTP))
                    {
                     PrintLog(LOG_VERBOSE, StringFormat("Trailing SL updated on %s BUY: %.5f",
                              sym, newSL));
                    }
                 }
              }
            else
              {
               newSL = NormalizeDouble(ask + trailDist, digits);
               if(newSL < currentSL && newSL > ask)
                 {
                  g_trade.SetExpertMagicNumber(magic);
                  if(g_trade.PositionModify(ticket, newSL, currentTP))
                    {
                     PrintLog(LOG_VERBOSE, StringFormat("Trailing SL updated on %s SELL: %.5f",
                              sym, newSL));
                    }
                 }
              }
           }
        }

      //--- Track position closures for cooldown
      if(!HasPosition(sym, magic) && g_states[i].barsSinceClose > 1000)
        {
         //--- Position was recently closed (this is approximate; reset on detection)
         //--- The barsSinceClose is reset properly via new-bar detection
        }
     }
  }

//+------------------------------------------------------------------+
//| Check if symbol has an open position with given magic             |
//+------------------------------------------------------------------+
bool HasPosition(string sym, int magic)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == sym &&
         PositionGetInteger(POSITION_MAGIC) == magic)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Get position type for symbol with given magic                     |
//+------------------------------------------------------------------+
ENUM_POSITION_TYPE GetPositionType(string sym, int magic)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == sym &&
         PositionGetInteger(POSITION_MAGIC) == magic)
         return (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
     }
   return POSITION_TYPE_BUY; // default (should not reach here if HasPosition checked first)
  }

//+------------------------------------------------------------------+
//| Close all positions for a symbol with given magic                 |
//+------------------------------------------------------------------+
void ClosePositions(string sym, int magic)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == sym &&
         PositionGetInteger(POSITION_MAGIC) == magic)
        {
         g_trade.SetExpertMagicNumber(magic);
         if(!g_trade.PositionClose(ticket))
           {
            PrintLog(LOG_MINIMAL, StringFormat("Failed to close position %I64u on %s: err=%d",
                     ticket, sym, GetLastError()));
           }
         else
           {
            PrintLog(LOG_NORMAL, StringFormat("Closed position %I64u on %s (flip/cleanup)",
                     ticket, sym));
            //--- Reset cooldown
            g_states[FindSymbolIndex(sym)].barsSinceClose = 0;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Count total open trades across all symbols with our magic range   |
//+------------------------------------------------------------------+
int CountOpenTrades()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      long posmagic = PositionGetInteger(POSITION_MAGIC);
      //--- Check if this position belongs to us (magic in our range)
      if(posmagic >= InpMagicNumberBase &&
         posmagic < InpMagicNumberBase + g_symbolCount)
         count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Find symbol index in g_states array                               |
//+------------------------------------------------------------------+
int FindSymbolIndex(string sym)
  {
   for(int i = 0; i < g_symbolCount; i++)
     {
      if(g_states[i].symbol == sym)
         return i;
     }
   return -1;
  }

//+------------------------------------------------------------------+
//| Check and reset daily tracking                                    |
//+------------------------------------------------------------------+
void CheckDailyReset()
  {
   MqlDateTime dt;
   TimeCurrent(dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);

   if(today != g_dailyResetDate)
     {
      g_dailyResetDate = today;
      g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyLimitHit = false;
      g_equityDDHit = false;
      g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      PrintLog(LOG_NORMAL, StringFormat("Daily reset. Start balance: %.2f", g_dailyStartBalance));
     }
  }

//+------------------------------------------------------------------+
//| Parse no-trade dates from input string                            |
//+------------------------------------------------------------------+
void ParseNoTradeDates(string rawDates)
  {
   if(StringLen(rawDates) == 0)
      return;

   string parts[];
   int count = StringSplit(rawDates, ';', parts);
   ArrayResize(g_noTradeDates, count);

   for(int i = 0; i < count; i++)
     {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      //--- Parse YYYY-MM-DD format
      g_noTradeDates[i] = StringToTime(parts[i]);
     }
  }

//+------------------------------------------------------------------+
//| Parse no-trade hours from input string                            |
//+------------------------------------------------------------------+
void ParseNoTradeHours(string rawHours)
  {
   if(StringLen(rawHours) == 0)
      return;

   string parts[];
   int count = StringSplit(rawHours, ';', parts);
   ArrayResize(g_noTradeHourStart, count);
   ArrayResize(g_noTradeHourEnd, count);

   for(int i = 0; i < count; i++)
     {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      string hourParts[];
      if(StringSplit(parts[i], '-', hourParts) == 2)
        {
         g_noTradeHourStart[i] = (int)StringToInteger(hourParts[0]);
         g_noTradeHourEnd[i]   = (int)StringToInteger(hourParts[1]);
        }
     }
  }

//+------------------------------------------------------------------+
//| Check if current date is a no-trade date                          |
//+------------------------------------------------------------------+
bool IsNoTradeDate()
  {
   int count = ArraySize(g_noTradeDates);
   if(count == 0)
      return false;

   MqlDateTime dtNow, dtCheck;
   TimeCurrent(dtNow);

   for(int i = 0; i < count; i++)
     {
      TimeToStruct(g_noTradeDates[i], dtCheck);
      if(dtNow.year == dtCheck.year && dtNow.mon == dtCheck.mon && dtNow.day == dtCheck.day)
        {
         PrintLog(LOG_VERBOSE, "No-trade date active");
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Check if current hour is in a no-trade window                     |
//+------------------------------------------------------------------+
bool IsNoTradeHour()
  {
   int count = ArraySize(g_noTradeHourStart);
   if(count == 0)
      return false;

   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;

   for(int i = 0; i < count; i++)
     {
      int start = g_noTradeHourStart[i];
      int end   = g_noTradeHourEnd[i];

      //--- Handle wrap-around (e.g., 22-2 means 22,23,0,1)
      if(start <= end)
        {
         if(hour >= start && hour < end)
           {
            PrintLog(LOG_VERBOSE, StringFormat("No-trade hour active: %d in [%d-%d)",
                     hour, start, end));
            return true;
           }
        }
      else
        {
         //--- Wrap around midnight
         if(hour >= start || hour < end)
           {
            PrintLog(LOG_VERBOSE, StringFormat("No-trade hour active: %d in [%d-%d)",
                     hour, start, end));
            return true;
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Calculate today's realized P/L from closed deals                  |
//+------------------------------------------------------------------+
double GetTodayPL()
  {
   double pl = AccountInfoDouble(ACCOUNT_BALANCE) - g_dailyStartBalance;
   return pl;
  }

//+------------------------------------------------------------------+
//| Self-test: log swing points for debugging                         |
//+------------------------------------------------------------------+
void LogSwingPoints(int idx)
  {
   double swLowPrice = 0, swHighPrice = 0;
   datetime swLowTime = 0, swHighTime = 0;

   if(FindLastSwingLow(idx, swLowPrice, swLowTime))
      PrintFormat("[SELFTEST] %s | Last Swing Low: %.5f at %s",
                  g_states[idx].symbol, swLowPrice, TimeToString(swLowTime));
   else
      PrintFormat("[SELFTEST] %s | No swing low found in lookback", g_states[idx].symbol);

   if(FindLastSwingHigh(idx, swHighPrice, swHighTime))
      PrintFormat("[SELFTEST] %s | Last Swing High: %.5f at %s",
                  g_states[idx].symbol, swHighPrice, TimeToString(swHighTime));
   else
      PrintFormat("[SELFTEST] %s | No swing high found in lookback", g_states[idx].symbol);
  }

//+------------------------------------------------------------------+
//| Trend state to string                                             |
//+------------------------------------------------------------------+
string TrendToString(ENUM_TREND_STATE trend)
  {
   switch(trend)
     {
      case TREND_BULL:    return "BULL";
      case TREND_BEAR:    return "BEAR";
      default:            return "NEUTRAL";
     }
  }

//+------------------------------------------------------------------+
//| Logging helper                                                    |
//+------------------------------------------------------------------+
void PrintLog(ENUM_LOG_LEVEL level, string message)
  {
   if(level <= InpLogLevel)
      PrintFormat("[SZA|%s] %s", LogLevelToString(level), message);
  }

//+------------------------------------------------------------------+
//| Log level to string                                               |
//+------------------------------------------------------------------+
string LogLevelToString(ENUM_LOG_LEVEL level)
  {
   switch(level)
     {
      case LOG_MINIMAL: return "ERR";
      case LOG_NORMAL:  return "INF";
      case LOG_VERBOSE: return "DBG";
      default:          return "---";
     }
  }

//+------------------------------------------------------------------+
//| Error printing helper                                             |
//+------------------------------------------------------------------+
void PrintError(string message)
  {
   PrintFormat("[SZA|ERROR] %s (err=%d)", message, GetLastError());
  }

//+------------------------------------------------------------------+
//| DASHBOARD – Create on-chart panel objects                         |
//+------------------------------------------------------------------+
void CreateDashboard()
  {
   //--- Background rectangle
   string bgName = DASH_PREFIX + "BG";
   int panelHeight = (7 + g_symbolCount) * DASH_LINE_HEIGHT + 10;
   ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, DASHBOARD_X);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, DASHBOARD_Y);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, 320);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, panelHeight);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, clrMidnightBlue);
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, clrSteelBlue);
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
   ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);

   //--- Title label
   CreateLabel("TITLE", "SZA EMA TripleTrend H1", 0, clrGold);

   //--- Symbol lines (will be updated)
   for(int i = 0; i < g_symbolCount; i++)
     {
      string name = "SYM" + IntegerToString(i);
      CreateLabel(name, g_states[i].symbol + ": ---", 1 + i, clrWhite);
     }

   //--- Info lines
   int baseRow = 1 + g_symbolCount + 1;
   CreateLabel("RISK",   "Risk: ---", baseRow, clrLightGray);
   CreateLabel("PL",     "Today P/L: ---", baseRow + 1, clrLightGray);
   CreateLabel("DD",     "Drawdown: ---", baseRow + 2, clrLightGray);
   CreateLabel("TRADES", "Trades: ---", baseRow + 3, clrLightGray);
   CreateLabel("MODE",   "Mode: " + EnumToString(InpEntryMode), baseRow + 4, clrLightGray);
  }

//+------------------------------------------------------------------+
//| Create a single dashboard text label                              |
//+------------------------------------------------------------------+
void CreateLabel(string suffix, string text, int row, color clr)
  {
   string name = DASH_PREFIX + suffix;
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, DASHBOARD_X + 8);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, DASHBOARD_Y + 6 + row * DASH_LINE_HEIGHT);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, DASH_FONT_SIZE);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| Update dashboard labels with current data                         |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   //--- Update symbol trend states
   for(int i = 0; i < g_symbolCount; i++)
     {
      string name = DASH_PREFIX + "SYM" + IntegerToString(i);
      string trendStr = TrendToString(g_states[i].trendState);
      string posStr = HasPosition(g_states[i].symbol, g_states[i].magicNumber) ? " [POS]" : "";
      string text = StringFormat("%-10s %s%s", g_states[i].symbol, trendStr, posStr);

      //--- Color based on trend
      color clr = clrGray;
      if(g_states[i].trendState == TREND_BULL)
         clr = clrLime;
      else if(g_states[i].trendState == TREND_BEAR)
         clr = clrTomato;

      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
     }

   //--- Update info rows
   int baseRow = 1 + g_symbolCount + 1;

   //--- Risk info
   string riskStr;
   if(InpRiskMode == RISK_PERCENT)
      riskStr = StringFormat("Risk: %.1f%% of balance", InpRiskPercent);
   else
      riskStr = StringFormat("Risk: %.2f %s", InpRiskCurrency,
                AccountInfoString(ACCOUNT_CURRENCY));
   ObjectSetString(0, DASH_PREFIX + "RISK", OBJPROP_TEXT, riskStr);

   //--- Today P/L
   double todayPL = GetTodayPL();
   string plStr = StringFormat("Today P/L: %.2f %s", todayPL,
                  AccountInfoString(ACCOUNT_CURRENCY));
   color plColor = todayPL >= 0 ? clrLime : clrTomato;
   ObjectSetString(0, DASH_PREFIX + "PL", OBJPROP_TEXT, plStr);
   ObjectSetInteger(0, DASH_PREFIX + "PL", OBJPROP_COLOR, plColor);

   //--- Drawdown
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = 0;
   if(g_peakEquity > 0)
      ddPct = (g_peakEquity - equity) / g_peakEquity * 100.0;
   string ddStr = StringFormat("Drawdown: %.2f%%", ddPct);
   if(g_dailyLimitHit)
      ddStr += " [LIMIT]";
   if(g_equityDDHit)
      ddStr += " [DD STOP]";
   ObjectSetString(0, DASH_PREFIX + "DD", OBJPROP_TEXT, ddStr);
   ObjectSetInteger(0, DASH_PREFIX + "DD", OBJPROP_COLOR, ddPct > 3.0 ? clrOrange : clrLightGray);

   //--- Open trades
   int openCount = CountOpenTrades();
   string trStr = StringFormat("Trades: %d / %d", openCount, InpMaxTradesTotal);
   ObjectSetString(0, DASH_PREFIX + "TRADES", OBJPROP_TEXT, trStr);

   //--- Force chart redraw
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| IsBullTrend – public helper for external use or readability       |
//+------------------------------------------------------------------+
bool IsBullTrend(string sym)
  {
   int idx = FindSymbolIndex(sym);
   if(idx < 0)
      return false;
   return g_states[idx].trendState == TREND_BULL;
  }

//+------------------------------------------------------------------+
//| IsBearTrend – public helper for external use or readability       |
//+------------------------------------------------------------------+
bool IsBearTrend(string sym)
  {
   int idx = FindSymbolIndex(sym);
   if(idx < 0)
      return false;
   return g_states[idx].trendState == TREND_BEAR;
  }

//+------------------------------------------------------------------+
//| End of Expert Advisor                                             |
//+------------------------------------------------------------------+
