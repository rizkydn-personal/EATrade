//+------------------------------------------------------------------+
//| XAUUSD_scalper_M1.mq5                                            |
//| Scalping M1: range breakout + trend EMA + ATR adaptif.           |
//| 1 sinyal = 3 order (TP bertingkat: TP1/TP2/TP3). Reversal        |
//| otomatis jika ada posisi terbuka berlawanan arah sinyal baru.    |
//|                                                                   |
//| Sumber sinyal (prioritas): BREAKOUT > PULLBACK > SR_REVERSAL >   |
//| MOMENTUM_REVERSAL. Detail lengkap tiap perubahan versi ada di    |
//| CHANGELOG.md di folder project ini.                              |
//+------------------------------------------------------------------+
#property strict
#property version   "3.07"

#include <Trade\Trade.mqh>
CTrade trade;

input group "=== General ==="
input long   InpMagicNumber       = 990022;
input string InpTradeComment      = "XAU-M1-MTP";
input ENUM_TIMEFRAMES InpTrendTF  = PERIOD_M15;   // trend filter lebih cepat mengikuti entry M1
input ENUM_TIMEFRAMES InpEntryTF  = PERIOD_M1;
input int    InpDeviationPoints   = 30;      // toleransi slippage market execution

input group "=== Breakout logic ==="
input int    InpTrendEmaFast      = 50;
input int    InpTrendEmaSlow      = 200;
input int    InpRangeBars         = 8;       // diperpendek dari 12 -> lebih sering breakout valid
input double InpBreakoutBufferPts = 10;      // diperkecil dari 20 -> ambang tembus lebih mudah
input double InpMinBodyATR        = 0.20;    // diperkecil dari 0.30 -> body candle lolos lebih mudah
input bool   InpRequireCloseNearExtreme = true;
input double InpCloseExtremePercent = 35.0;  // dilonggarkan dari 25 -> toleransi close lebih besar

input group "=== Volatility (adaptif) ==="
input int    InpAtrPeriod         = 14;
input int    InpAtrBaselineBars   = 150;     // median ATR dari N bar terakhir sbg baseline
input double InpAtrMinMultiplier  = 0.40;    // dilonggarkan dari 0.50
input double InpAtrMaxMultiplier  = 3.00;    // dilonggarkan dari 2.50
input double InpMaxSpreadATRPercent = 30.0;  // spread maks = sekian % dari ATR skrg
input double InpMaxSpreadPointsHardCap = 600; // hard cap absolut, jaring pengaman kedua

input group "=== Risk management ==="
input double InpRiskPercent       = 0.50;    // risiko total per sinyal (dibagi ke 3 leg)
input double InpAtrSLMultiplier   = 1.10;    // SL lebih rapat drpd versi M5 (sesuai skala M1)
input double InpMaxDailyLossPercent = 10.0;   // batas rugi harian (%) sebelum EA berhenti trading
input double InpMaxLotSize        = 5.0;
input double InpMaxDailyProfitPercent = 0.0;    // target profit harian (%) (0 = nonaktif)
input int    InpMaxTradesPerDay   = 3000;       // batas jumlah sinyal/trade per hari saat mode Default (0 = tanpa batas)
input int    InpMaxOpenPositions  = 6;       // HARD CAP jumlah posisi aktif (semua leg TP1/2/3 dihitung) - sinyal baru ditahan kalau tercapai

input group "=== SL Anti-Stophunt (SL lebih tahan noise, TP tidak ikut melebar) ==="
input double InpSLNoiseBufferATR    = 0.35;   // buffer tambahan (x ATR) di atas SL dasar, meredam wick/noise M1
input double InpSLSpreadBufferMult  = 1.5;    // buffer tambahan = spread saat ini x nilai ini, ditambah ke SL
input bool   InpDecoupleTPFromSL    = true;   // true = TP dihitung dari SL DASAR (sebelum buffer), SL boleh lebih lebar tanpa TP ikut menjauh
input bool   InpEnableBreakEven     = true;   // pindahkan SL ke breakeven+buffer setelah profit floating cukup
input double InpBreakEvenTriggerRR  = 0.5;    // ambang trigger breakeven, dalam kelipatan SL DASAR (bukan SL lebar aktual)
input double InpBreakEvenBufferPoints = 50;   // SL breakeven digeser sejauh ini (poin) dari harga entry, searah profit

input group "=== Multi-TP (1 sinyal = 3 order) ==="
input double InpTP1_RR            = 0.8;     // TP cepat, kunci profit awal
input double InpTP2_RR            = 1.3;
input double InpTP3_RR            = 2.2;     // TP jauh, biar lari kalau momentum kuat
input double InpTP1VolumePercent  = 40.0;    // total 3 leg harus = 100
input double InpTP2VolumePercent  = 35.0;
input double InpTP3VolumePercent  = 25.0;

input group "=== Support/Resistance (SR Reversal) ==="
input bool   InpEnableSRReversal   = true;    // aktifkan mode reversal di S/R (agar SELL bisa terjadi walau EMA trend naik)
input ENUM_TIMEFRAMES InpSRTF      = PERIOD_M15;  // timeframe pencarian swing high/low utk S/R
input int    InpSRFractalDepth     = 2;       // jumlah bar kiri/kanan utk validasi fractal (2 = fractal 5 candle standar)
input int    InpSRLookbackBars     = 150;     // jumlah bar InpSRTF yang discan utk cari level S/R
input int    InpSRMaxLevels        = 6;       // jumlah level S/R terdekat yg disimpan per sisi (resistance/support)
input double InpSRZoneATRMult      = 0.30;    // lebar zona toleransi S/R = ATR x ini (utk gabung level berdekatan)
input int    InpSRMinTouches       = 1;       // jumlah minimum swing point yg menyatu jadi 1 level valid
input double InpSRRejectionWickPercent = 30.0; // dilonggarkan dari 40 -> rejection lebih mudah lolos
input bool   InpSRRequireEmaAlign  = false;   // true = reversal SR tetap difilter searah EMA trend (mode konservatif)
input int    InpSRRecalcIntervalSec = 180;    // dipercepat dari 300 -> level S/R lebih update
input double InpSRMinRangeATR      = 2.50;    // jarak MINIMAL resistance-support (x ATR) supaya SR_REVERSAL boleh entry.
                                               // Kalau range lebih sempit dari ini, market dianggap sideways sempit -
                                               // resistance & support terlalu berdekatan -> sinyal SR_REVERSAL ditahan
                                               // (di kotak sempit ini yang paling sering memicu lost trade saat backtest)

input group "=== EMA Pullback Continuation (tambahan frekuensi) ==="
input bool   InpEnablePullback     = true;    // aktifkan mode pullback M1 (sumber sinyal paling sering, tetap searah EMA trend)
input int    InpPullbackEmaPeriod  = 20;      // EMA M1 acuan pullback
input double InpPullbackTouchATR   = 0.35;    // toleransi "menyentuh" EMA = ATR x ini
input double InpPullbackMinBodyATR = 0.20;    // body candle continuation minimal (x ATR)

input group "=== Multi-Timeframe Trend Confirmation (M1) ==="
input bool   InpRequireM1TrendAlign = true;   // true = BREAKOUT/PULLBACK ditahan kalau trend M1 berlawanan dgn trend M15 (cegah entry searah trend M15 yg sudah basi)
input int    InpM1TrendEmaFast      = 9;      // EMA cepat M1 utk cek momentum jangka pendek
input int    InpM1TrendEmaSlow      = 21;     // EMA lambat M1 utk cek momentum jangka pendek

input group "=== Momentum Reversal (reversal di luar zona S/R) ==="
input bool   InpEnableMomentumReversal = true;   // aktifkan sinyal reversal berbasis momentum M1 (tidak harus persis di S/R)
input double InpMomentumMinBodyATR     = 0.45;   // body candle reversal minimal (x ATR) - lebih besar dari breakout biasa agar tdk overtrade
input int    InpMomentumConfirmBars    = 2;      // jumlah candle M1 berturut-turut yg harus konsisten berlawanan trend M15

input group "=== Dashboard logging ==="
input bool   InpEnableFileLogging = true;
input bool   InpUseCommonFolder   = true;
input string InpStatusFileName    = "range_breakout_m1_status.json";
input string InpEventsFileName    = "range_breakout_m1_events.json";
input int    InpStatusWriteIntervalSec = 3;
input int    InpScanLogIntervalSec = 3;
input string InpCommandFileName   = "bot_command.json";
input int    InpCommandPollIntervalSec = 3;

int hEmaFast = INVALID_HANDLE, hEmaSlow = INVALID_HANDLE, hAtr = INVALID_HANDLE, hEmaPullback = INVALID_HANDLE;
int hEmaM1Fast = INVALID_HANDLE, hEmaM1Slow = INVALID_HANDLE;
datetime lastBarTime = 0, lastTickTime = 0, lastStatusWrite = 0, lastScanLog = 0;
datetime dayStartTime = 0;
double dayStartEquity = 0;
int tradesToday = 0;
bool halted = false, indicatorsReady = false;
string haltReason = "", scanState = "INIT", scanDetail = "EA belum menerima tick";
string lastSignal = "None";
datetime lastSignalTime = 0;
string currentMode = "DEFAULT_RECOMMENDED";
datetime lastCommandPoll = 0;

// ======================== SUPPORT/RESISTANCE STATE ========================
double   gSRResistance[];      // level resistance tercache, hasil merge swing high
double   gSRSupport[];         // level support tercache, hasil merge swing low
datetime lastSRCalcTime = 0;
double   lastResistance = 0, lastSupport = 0; // level S/R terdekat dari harga saat ini (utk status/dashboard)
string   lastSignalMode = "-"; // "BREAKOUT" atau "SR_REVERSAL"

string GetWIBTimeString()
{
   datetime wib = TimeCurrent() + 7 * 3600; // WIB = UTC+7
   return TimeToString(wib, TIME_DATE | TIME_SECONDS);
}

string JsonEscape(string value)
  {
   StringReplace(value,"\\","\\\\");
   StringReplace(value,"\"","\\\"");
   return value;
  }

// Ambil value string dari JSON sederhana satu level
string ExtractJsonStringValue(string json,string key)
  {
   string needle="\""+key+"\"";
   int pos=StringFind(json,needle);
   if(pos<0) return "";
   int colon=StringFind(json,":",pos);
   if(colon<0) return "";
   int q1=StringFind(json,"\"",colon+1);
   if(q1<0) return "";
   int q2=StringFind(json,"\"",q1+1);
   if(q2<0) return "";
   return StringSubstr(json,q1+1,q2-q1-1);
  }

void PollCommandFile()
  {
   if(TimeCurrent()-lastCommandPoll<InpCommandPollIntervalSec) return;
   lastCommandPoll=TimeCurrent();
   int checkFlag=(InpUseCommonFolder?FILE_COMMON:0);
   if(!FileIsExist(InpCommandFileName,checkFlag)) return;
   int flags=FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE;
   if(InpUseCommonFolder) flags|=FILE_COMMON;
   int file=FileOpen(InpCommandFileName,flags);
   if(file==INVALID_HANDLE) return;
   string content="";
   while(!FileIsEnding(file)) content+=FileReadString(file)+" ";
   FileClose(file);
   string mode=ExtractJsonStringValue(content,"mode");
   if((mode=="DEFAULT_RECOMMENDED" || mode=="H24_UNLIMITED") && mode!=currentMode)
     {
      currentMode=mode;
      AppendEvent("MODE_CHANGED",StringFormat("Mode trading diubah ke %s lewat dashboard",currentMode));
     }
  }

// ======================== PERBAIKAN APPEND EVENT ========================
void AppendEvent(string eventType, string detail)
  {
   if(!InpEnableFileLogging) return;

   // Buat baris JSON baru
   string newLine = StringFormat("{\"time\":\"%s\",\"symbol\":\"%s\",\"event\":\"%s\",\"detail\":\"%s\"}",
                                  TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                                  _Symbol,
                                  eventType,
                                  JsonEscape(detail));

   int commonFlag = InpUseCommonFolder ? FILE_COMMON : 0;

   string oldLines[];
   int lineCount = 0;
   ArrayResize(oldLines, 0);

   int readFlags = FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE|commonFlag;
   int rfile = FileOpen(InpEventsFileName, readFlags);
   if(rfile != INVALID_HANDLE)
     {
      while(!FileIsEnding(rfile))
        {
         string ln = FileReadString(rfile);
         if(StringLen(ln) > 0)
           {
            ArrayResize(oldLines, lineCount+1);
            oldLines[lineCount] = ln;
            lineCount++;
           }
        }
      FileClose(rfile);
     }

   ArrayResize(oldLines, lineCount+1);
   oldLines[lineCount] = newLine;
   lineCount++;

   int maxLines = 5;
   int startIdx = (lineCount > maxLines) ? (lineCount - maxLines) : 0;

   int writeFlags = FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE|commonFlag;
   int wfile = FileOpen(InpEventsFileName, writeFlags);
   if(wfile == INVALID_HANDLE) return;

   for(int i = startIdx; i < lineCount; i++)
      FileWriteString(wfile, oldLines[i] + "\r\n");

   FileClose(wfile);
  }

void SetScanState(string state,string detail)
  {
   bool changed=(state!=scanState);
   scanState=state; scanDetail=detail;
   if(changed || TimeCurrent()-lastScanLog>=InpScanLogIntervalSec)
     {
      lastScanLog=TimeCurrent();
      Print("SCAN [",state,"] ",detail);
      AppendEvent("SCAN",StringFormat("[%s] %s",state,detail));
     }
  }

string PositionTypeLabel(int type)
  {
   if(type==POSITION_TYPE_BUY) return "BUY";
   if(type==POSITION_TYPE_SELL) return "SELL";
   return "NONE";
  }

int GetOurPositionType()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
         return (int)PositionGetInteger(POSITION_TYPE);
     }
   return -1;
  }

int CountOurPositions()
  {
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) count++;
     }
   return count;
  }

bool CloseAllOurPositions()
  {
   bool allOk=true;
   SetUniversalFillingMode(_Symbol);
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
        {
         if(!trade.PositionClose(ticket))
           {
            allOk=false;
            AppendEvent("CLOSE_FAILED",StringFormat("ticket %I64u: %s",ticket,trade.ResultRetcodeDescription()));
           }
        }
     }
   return allOk;
  }

// ======================== PERBAIKAN WRITE STATUS ========================
// Menambahkan FILE_SHARE_READ | FILE_SHARE_WRITE agar dashboard dapat membaca
void WriteStatus()
  {
   if(!InpEnableFileLogging || TimeCurrent()-lastStatusWrite<InpStatusWriteIntervalSec) return;
   lastStatusWrite=TimeCurrent();
   int positions=CountOurPositions();
   string posType=PositionTypeLabel(GetOurPositionType());
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double pnl=(dayStartEquity>0 ? (equity-dayStartEquity)/dayStartEquity*100.0 : 0.0);
   int maxTradesEffective=(currentMode=="H24_UNLIMITED")?0:InpMaxTradesPerDay;
   string json=StringFormat("{\"timestamp\":\"%s\",\"magic\":%I64d,\"symbol\":\"%s\",\"mode\":\"%s\",\"strategy\":\"RANGE_BREAKOUT_M1_MULTITP\",\"trading_halted_today\":%s,\"halt_reason\":\"%s\",\"trades_today\":%d,\"max_trades_per_day\":%d,\"daily_pnl_percent\":%.2f,\"max_daily_loss_percent\":%.2f,\"max_daily_profit_percent\":%.2f,\"equity\":%.2f,\"balance\":%.2f,\"risk_percent_per_trade\":%.2f,\"open_positions\":%d,\"position_type\":\"%s\",\"last_signal\":\"%s\",\"last_signal_mode\":\"%s\",\"last_signal_time\":\"%s\",\"sr_resistance\":%.2f,\"sr_support\":%.2f,\"sr_reversal_enabled\":%s,\"scan_state\":\"%s\",\"scan_detail\":\"%s\",\"last_tick_time\":\"%s\",\"indicators_ready\":%s,\"ea_running\":true}",
                            GetWIBTimeString(),
                            InpMagicNumber,
                            _Symbol,
                            currentMode,
                            halted?"true":"false",
                            JsonEscape(haltReason),
                            tradesToday,
                            maxTradesEffective,
                            pnl,
                            InpMaxDailyLossPercent,
                            InpMaxDailyProfitPercent,
                            equity,
                            AccountInfoDouble(ACCOUNT_BALANCE),
                            InpRiskPercent,
                            positions,
                            posType,
                            lastSignal,
                            lastSignalMode,
                            lastSignalTime>0?TimeToString(lastSignalTime,TIME_DATE|TIME_SECONDS):"-",
                            lastResistance,
                            lastSupport,
                            InpEnableSRReversal?"true":"false",
                            JsonEscape(scanState),
                            JsonEscape(scanDetail),
                            lastTickTime>0?TimeToString(lastTickTime,TIME_DATE|TIME_SECONDS):"-",
                            indicatorsReady?"true":"false");
   int flags=FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE;
   if(InpUseCommonFolder) flags|=FILE_COMMON;
   int file=FileOpen(InpStatusFileName,flags);
   if(file!=INVALID_HANDLE) { FileWriteString(file,json); FileClose(file); }
  }

void ResetDay()
  {
   dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY); dayStartTime=TimeCurrent(); tradesToday=0; halted=false; haltReason="";
  }

void CheckNewDay()
  {
   MqlDateTime now,start; TimeToStruct(TimeCurrent(),now); TimeToStruct(dayStartTime,start);
   if(now.year!=start.year || now.mon!=start.mon || now.day!=start.day) ResetDay();
  }

double GetBufferValue(int handle,int shift=1)
  {
   double data[]; ArraySetAsSeries(data,true);
   if(CopyBuffer(handle,0,shift,1,data)!=1) return 0.0;
   return data[0];
  }

double GetAtrBaseline(int bars)
  {
   double buf[]; ArraySetAsSeries(buf,true);
   int got=CopyBuffer(hAtr,0,1,bars,buf);
   if(got<=0) return 0.0;
   double sorted[]; ArrayResize(sorted,got);
   for(int i=0;i<got;i++) sorted[i]=buf[i];
   ArraySort(sorted);
   int mid=got/2;
   if(got%2==1) return sorted[mid];
   return (sorted[mid-1]+sorted[mid])/2.0;
  }

int TrendDirection()
  {
   double fast=GetBufferValue(hEmaFast),slow=GetBufferValue(hEmaSlow);
   if(fast==0 || slow==0) return 0;
   return fast>slow ? 1 : (fast<slow ? -1 : 0);
  }

// Trend cepat berbasis EMA M1 (fast/slow) - dipakai utk konfirmasi momentum jangka pendek,
// agar EA tidak terus membuka posisi searah trend M15 yang sudah basi saat harga M1 sudah reversal.
int M1TrendDirection()
  {
   double fast=GetBufferValue(hEmaM1Fast),slow=GetBufferValue(hEmaM1Slow);
   if(fast==0 || slow==0) return 0;
   return fast>slow ? 1 : (fast<slow ? -1 : 0);
  }

double NormalizeVolume(double volume)
  {
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN), maxLot=MathMin(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),InpMaxLotSize), step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0 || volume<minLot) return 0;
   volume=MathFloor(volume/step)*step;
   return NormalizeDouble(MathMin(volume,maxLot),2);
  }

double CalculateVolume(double entry,double sl)
  {
   // Tick value berasal dari broker dalam currency deposit akun. Karena itu
   // rumus ini aman untuk akun cent dan cross-currency: jangan mengonversi
   // equity/balance dengan asumsi USD atau contract size tertentu.
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValueLoss=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValueLoss<=0) tickValueLoss=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double distance=MathAbs(entry-sl);
   if(tickSize<=0 || tickValueLoss<=0 || distance<=0) return 0;
   return NormalizeVolume((AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0)/(distance/tickSize*tickValueLoss));
  }

void SetUniversalFillingMode(const string symbol)
  {
   // SYMBOL_FILLING_MODE adalah bitmask broker. Pilih mode yang tersedia
   // sebelum setiap OrderSend (CTrade.Buy/Sell maupun PositionClose) agar EA
   // tidak bergantung pada IOC/FOK hardcode milik broker tertentu.
   long fillingMask=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
   if((fillingMask & SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillingMask & SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
  }

double EnforceMinStopDistance(double price,double level,bool isAbove)
  {
   long stopLevelPts=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPts=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double minDistPts=(double)MathMax(stopLevelPts,freezeLevelPts);
   if(minDistPts<=0) return level;
   double minDist=minDistPts*_Point;
   double curDist=MathAbs(price-level);
   if(curDist>=minDist) return level;
   return isAbove ? price+minDist : price-minDist;
  }

bool IsBreakoutSignal(int trend,double atr,string &reason)
  {
   int need=InpRangeBars+2;
   MqlRates rates[]; ArraySetAsSeries(rates,true);
   if(CopyRates(_Symbol,InpEntryTF,1,need,rates)!=need) { reason="History belum cukup"; return false; }
   double rangeHigh=rates[1].high,rangeLow=rates[1].low;
   for(int i=1;i<=InpRangeBars;i++) { rangeHigh=MathMax(rangeHigh,rates[i].high); rangeLow=MathMin(rangeLow,rates[i].low); }
   double body=MathAbs(rates[0].close-rates[0].open), candleRange=rates[0].high-rates[0].low;
   if(candleRange<=0 || body<atr*InpMinBodyATR) { reason="Body candle breakout terlalu kecil"; return false; }
   double buffer=InpBreakoutBufferPts*_Point;
   if(trend==1 && rates[0].close>rangeHigh+buffer)
     {
      if(InpRequireCloseNearExtreme && (rates[0].high-rates[0].close)>candleRange*InpCloseExtremePercent/100.0) { reason="Buy close tidak cukup dekat high"; return false; }
      reason=StringFormat("BUY close %.2f > range high %.2f",rates[0].close,rangeHigh); return true;
     }
   if(trend==-1 && rates[0].close<rangeLow-buffer)
     {
      if(InpRequireCloseNearExtreme && (rates[0].close-rates[0].low)>candleRange*InpCloseExtremePercent/100.0) { reason="Sell close tidak cukup dekat low"; return false; }
      reason=StringFormat("SELL close %.2f < range low %.2f",rates[0].close,rangeLow); return true;
     }
   reason="Candle belum menembus range searah trend"; return false;
  }

// ======================== SUPPORT/RESISTANCE (S/R) ========================
// Gabungkan swing point yg berdekatan (dlm jarak zoneWidth) jadi satu level,
// hanya simpan level yg jumlah sentuhannya >= minTouches.
void MergeLevels(double &raw[],int count,double zoneWidth,int minTouches,double &outLevels[])
  {
   ArrayResize(outLevels,0);
   if(count<=0 || zoneWidth<=0) return;
   double sorted[]; ArrayResize(sorted,count);
   for(int i=0;i<count;i++) sorted[i]=raw[i];
   ArraySort(sorted); // ascending

   double clusterSum=0; int clusterCount=0; double clusterStart=sorted[0];
   for(int i=0;i<count;i++)
     {
      if(clusterCount==0) { clusterSum=sorted[i]; clusterCount=1; clusterStart=sorted[i]; continue; }
      if(sorted[i]-clusterStart<=zoneWidth) { clusterSum+=sorted[i]; clusterCount++; continue; }
      if(clusterCount>=minTouches)
        {
         int n=ArraySize(outLevels); ArrayResize(outLevels,n+1); outLevels[n]=clusterSum/clusterCount;
        }
      clusterSum=sorted[i]; clusterCount=1; clusterStart=sorted[i];
     }
   if(clusterCount>=minTouches)
     {
      int n=ArraySize(outLevels); ArrayResize(outLevels,n+1); outLevels[n]=clusterSum/clusterCount;
     }
  }

// Simpan hanya N level terdekat dari harga saat ini (insertion sort by jarak, array biasanya kecil)
void TrimNearestLevels(double &levels[],double price,int maxCount)
  {
   int n=ArraySize(levels);
   if(n<=maxCount) return;
   double dist[]; int idx[]; ArrayResize(dist,n); ArrayResize(idx,n);
   for(int i=0;i<n;i++) { dist[i]=MathAbs(levels[i]-price); idx[i]=i; }
   for(int i=1;i<n;i++)
     {
      double keyDist=dist[i]; int keyIdx=idx[i]; int j=i-1;
      while(j>=0 && dist[j]>keyDist) { dist[j+1]=dist[j]; idx[j+1]=idx[j]; j--; }
      dist[j+1]=keyDist; idx[j+1]=keyIdx;
     }
   double trimmed[]; ArrayResize(trimmed,maxCount);
   for(int i=0;i<maxCount;i++) trimmed[i]=levels[idx[i]];
   ArrayResize(levels,maxCount);
   for(int i=0;i<maxCount;i++) levels[i]=trimmed[i];
  }

// Scan swing high/low (fractal N-kiri N-kanan) di InpSRTF, lalu gabungkan jadi level S/R.
// Dibatasi interval InpSRRecalcIntervalSec supaya tidak menghitung ulang tiap tick.
void RecalcSRLevels()
  {
   if(lastSRCalcTime>0 && TimeCurrent()-lastSRCalcTime<InpSRRecalcIntervalSec) return;
   lastSRCalcTime=TimeCurrent();

   int depth=InpSRFractalDepth;
   int need=InpSRLookbackBars+depth*2+2;
   MqlRates rates[]; ArraySetAsSeries(rates,true);
   int got=CopyRates(_Symbol,InpSRTF,1,need,rates);
   if(got<depth*2+10) return; // history belum cukup, pertahankan level lama

   double rawHighs[]; double rawLows[]; ArrayResize(rawHighs,got); ArrayResize(rawLows,got);
   int nh=0, nl=0;
   for(int i=depth;i<got-depth;i++)
     {
      bool isHigh=true, isLow=true;
      for(int k=1;k<=depth;k++)
        {
         if(rates[i].high<rates[i-k].high || rates[i].high<rates[i+k].high) isHigh=false;
         if(rates[i].low>rates[i-k].low  || rates[i].low>rates[i+k].low)   isLow=false;
        }
      if(isHigh) rawHighs[nh++]=rates[i].high;
      if(isLow)  rawLows[nl++]=rates[i].low;
     }
   ArrayResize(rawHighs,nh);
   ArrayResize(rawLows,nl);

   double atr=GetBufferValue(hAtr);
   if(atr<=0) atr=SymbolInfoDouble(_Symbol,SYMBOL_POINT)*200; // fallback kalau ATR belum siap
   double zoneWidth=atr*InpSRZoneATRMult;

   MergeLevels(rawHighs,nh,zoneWidth,InpSRMinTouches,gSRResistance);
   MergeLevels(rawLows,nl,zoneWidth,InpSRMinTouches,gSRSupport);

   double curPrice=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(curPrice>0)
     {
      TrimNearestLevels(gSRResistance,curPrice,InpSRMaxLevels);
      TrimNearestLevels(gSRSupport,curPrice,InpSRMaxLevels);
     }
   AppendEvent("SR_RECALC",StringFormat("Resistance levels=%d, Support levels=%d (TF %s, lookback %d)",
               ArraySize(gSRResistance),ArraySize(gSRSupport),EnumToString(InpSRTF),InpSRLookbackBars));
  }

// Ambil resistance terdekat di atas price & support terdekat di bawah price dari cache.
bool GetNearestSR(double price,double &resistance,double &support)
  {
   resistance=0; support=0;
   double bestResDist=DBL_MAX, bestSupDist=DBL_MAX;
   for(int i=0;i<ArraySize(gSRResistance);i++)
     {
      double lvl=gSRResistance[i];
      if(lvl>price && lvl-price<bestResDist) { bestResDist=lvl-price; resistance=lvl; }
     }
   for(int i=0;i<ArraySize(gSRSupport);i++)
     {
      double lvl=gSRSupport[i];
      if(lvl<price && price-lvl<bestSupDist) { bestSupDist=price-lvl; support=lvl; }
     }
   return (resistance>0 || support>0);
  }

// Sinyal reversal: candle M1 terakhir menyentuh zona S/R lalu ditolak (wick panjang, close balik).
// dir: 1 = BUY (rejection di support), -1 = SELL (rejection di resistance). Tidak digembok oleh EMA trend.
bool IsSRReversalSignal(double atr,int &dir,double &srLevel,string &reason)
  {
   dir=0; srLevel=0; reason="";
   RecalcSRLevels();

   MqlRates rates[]; ArraySetAsSeries(rates,true);
   if(CopyRates(_Symbol,InpEntryTF,1,2,rates)!=2) { reason="History M1 belum cukup utk cek S/R"; return false; }

   double resistance=0, support=0;
   if(!GetNearestSR(rates[0].close,resistance,support))
     { reason="Belum ada level S/R yang terdeteksi (butuh lebih banyak history "+EnumToString(InpSRTF)+")"; return false; }

   // --- Filter market sideways sempit: kalau resistance & support (kotak) terlalu berdekatan,
   // rejection di satu sisi gampang langsung kena sisi lain / whipsaw -> ini sumber lost trade
   // paling sering di backtest saat market side aways. SR_REVERSAL DITAHAN kalau range < InpSRMinRangeATR x ATR.
   if(resistance>0 && support>0)
     {
      double srRange=resistance-support;
      double minRange=atr*InpSRMinRangeATR;
      if(srRange<minRange)
        {
         reason=StringFormat("Range S/R %.2f (res %.2f - sup %.2f) < minimum %.2f (%.2fx ATR) - market sideways sempit, SR_REVERSAL ditahan",
                              srRange,resistance,support,minRange,InpSRMinRangeATR);
         return false;
        }
     }

   double zoneWidth=atr*InpSRZoneATRMult;
   double candleRange=rates[0].high-rates[0].low;
   if(candleRange<=0) { reason="Range candle nol"; return false; }

   if(resistance>0 && rates[0].high>=resistance-zoneWidth)
     {
      double upperWick=rates[0].high-MathMax(rates[0].open,rates[0].close);
      if(upperWick>=candleRange*InpSRRejectionWickPercent/100.0 && rates[0].close<resistance)
        {
         dir=-1; srLevel=resistance;
         reason=StringFormat("Rejection di resistance %.2f (high %.2f, close %.2f)",resistance,rates[0].high,rates[0].close);
         return true;
        }
     }

   if(support>0 && rates[0].low<=support+zoneWidth)
     {
      double lowerWick=MathMin(rates[0].open,rates[0].close)-rates[0].low;
      if(lowerWick>=candleRange*InpSRRejectionWickPercent/100.0 && rates[0].close>support)
        {
         dir=1; srLevel=support;
         reason=StringFormat("Rejection di support %.2f (low %.2f, close %.2f)",support,rates[0].low,rates[0].close);
         return true;
        }
     }

   reason="Harga belum berada di zona S/R dengan rejection valid"; return false;
  }

// Sinyal continuation: harga pullback ke EMA M1 lalu lanjut searah trend EMA.
// Sumber sinyal paling sering (tiap kali ada pullback dangkal), tetap searah trend -> jaga kualitas.
bool IsPullbackSignal(int trend,double atr,string &reason)
  {
   reason="";
   if(trend==0) { reason="EMA trend belum jelas"; return false; }
   double emaP=GetBufferValue(hEmaPullback);
   if(emaP<=0) { reason="EMA pullback belum siap"; return false; }

   MqlRates rates[]; ArraySetAsSeries(rates,true);
   if(CopyRates(_Symbol,InpEntryTF,1,2,rates)!=2) { reason="History M1 belum cukup utk cek pullback"; return false; }

   double touchTol=atr*InpPullbackTouchATR;
   double body=MathAbs(rates[0].close-rates[0].open);
   if(body<atr*InpPullbackMinBodyATR) { reason="Body candle continuation terlalu kecil"; return false; }

   if(trend==1)
     {
      bool touched=(rates[0].low<=emaP+touchTol);
      bool continuation=(rates[0].close>rates[0].open && rates[0].close>emaP);
      if(touched && continuation)
        { reason=StringFormat("Pullback ke EMA%d (%.2f), continuation close %.2f",InpPullbackEmaPeriod,emaP,rates[0].close); return true; }
      reason="Belum ada pullback+continuation valid ke arah BUY"; return false;
     }
   else
     {
      bool touched=(rates[0].high>=emaP-touchTol);
      bool continuation=(rates[0].close<rates[0].open && rates[0].close<emaP);
      if(touched && continuation)
        { reason=StringFormat("Pullback ke EMA%d (%.2f), continuation close %.2f",InpPullbackEmaPeriod,emaP,rates[0].close); return true; }
      reason="Belum ada pullback+continuation valid ke arah SELL"; return false;
     }
  }

// Sinyal reversal berbasis momentum M1, TIDAK terikat harus persis di zona S/R.
// Syarat: EMA cepat/lambat M1 sudah flip berlawanan dgn trend M15 (konsisten InpMomentumConfirmBars
// candle terakhir), + candle terbaru punya body kuat (>= atr*InpMomentumMinBodyATR) searah flip itu.
// Ini menutup celah dimana SELL/BUY reversal hanya bisa muncul lewat SR_REVERSAL di level resisten/support -
// sekarang reversal momentum murni (di luar S/R) juga bisa memicu entry/menutup posisi lawan arah.
bool IsMomentumReversalSignal(int m15trend,double atr,int &dir,string &reason)
  {
   dir=0; reason="";
   if(m15trend==0) { reason="EMA trend M15 belum jelas"; return false; }

   int need=InpMomentumConfirmBars+1;
   MqlRates rates[]; ArraySetAsSeries(rates,true);
   if(CopyRates(_Symbol,InpEntryTF,1,need,rates)!=need) { reason="History M1 belum cukup utk cek momentum reversal"; return false; }

   double fastBuf[],slowBuf[]; ArraySetAsSeries(fastBuf,true); ArraySetAsSeries(slowBuf,true);
   if(CopyBuffer(hEmaM1Fast,0,1,InpMomentumConfirmBars,fastBuf)!=InpMomentumConfirmBars) { reason="EMA M1 cepat belum siap"; return false; }
   if(CopyBuffer(hEmaM1Slow,0,1,InpMomentumConfirmBars,slowBuf)!=InpMomentumConfirmBars) { reason="EMA M1 lambat belum siap"; return false; }

   int wantM1Trend=-m15trend; // kebalikan trend M15 = arah reversal yg dicari
   for(int i=0;i<InpMomentumConfirmBars;i++)
     {
      int dirI=(fastBuf[i]>slowBuf[i]?1:(fastBuf[i]<slowBuf[i]?-1:0));
      if(dirI!=wantM1Trend) { reason="Momentum M1 belum konsisten berlawanan trend M15"; return false; }
     }

   double body=MathAbs(rates[0].close-rates[0].open);
   if(body<atr*InpMomentumMinBodyATR) { reason="Body candle reversal momentum terlalu kecil"; return false; }

   if(wantM1Trend==-1 && rates[0].close<rates[0].open)
     {
      dir=-1;
      reason=StringFormat("Momentum reversal SELL: EMA M1 %d/%d flip turun %d candle, body %.2f",InpM1TrendEmaFast,InpM1TrendEmaSlow,InpMomentumConfirmBars,body);
      return true;
     }
   if(wantM1Trend==1 && rates[0].close>rates[0].open)
     {
      dir=1;
      reason=StringFormat("Momentum reversal BUY: EMA M1 %d/%d flip naik %d candle, body %.2f",InpM1TrendEmaFast,InpM1TrendEmaSlow,InpMomentumConfirmBars,body);
      return true;
     }
   reason="Momentum flip terdeteksi tapi candle terakhir belum konfirmasi arah"; return false;
  }

void OpenMultiTPEntry(int trend,double atr,string reason,string signalMode="BREAKOUT",double srInvalidationLevel=0,int maxLegsAllowed=3)
  {
   // Jaring pengaman kedua utk hard cap posisi: tidak pernah buka leg lebih banyak dari slot tersisa,
   // walau caller sudah cek CountOurPositions() sebelumnya (mis. race dgn trade manual/EA lain).
   if(maxLegsAllowed<=0) { SetScanState("MAX_POSITIONS_REACHED","Slot posisi sudah penuh, sinyal dibatalkan"); return; }
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) { SetScanState("PRICE_UNAVAILABLE","Tick harga belum tersedia"); return; }
   double entry=(trend==1 ? tick.ask : tick.bid);

   // ---- SL DASAR: dipakai sbg acuan TP (RR) & referensi trigger breakeven. TIDAK dikirim langsung ke broker. ----
   double baseSLDistance=atr*InpAtrSLMultiplier;
   double sl=(trend==1 ? entry-baseSLDistance : entry+baseSLDistance);
   if(srInvalidationLevel>0)
     {
      // Untuk reversal S/R, SL minimal harus melewati level yg invalid-kan setup (+ buffer zona),
      // jangan sampai lebih rapat drpd itu walau ATR kecil.
      double zoneWidth=atr*InpSRZoneATRMult;
      if(trend==1) sl=MathMin(sl,srInvalidationLevel-zoneWidth);
      else         sl=MathMax(sl,srInvalidationLevel+zoneWidth);
     }
   baseSLDistance=MathAbs(entry-sl); // sinkronkan ulang kalau kena penyesuaian S/R di atas

   // ---- SL AKTUAL: SL dasar + buffer anti-noise (ATR) + buffer spread real-time. ----
   // Ini yang membuat SL tidak gampang tersentuh oleh wick M1 / pelebaran spread sesaat.
   // TP TIDAK memakai jarak ini (lihat InpDecoupleTPFromSL di bawah), jadi TP tidak ikut menjauh.
   double spreadNow=MathMax(tick.ask-tick.bid,0);
   double noiseBuffer=atr*InpSLNoiseBufferATR+spreadNow*InpSLSpreadBufferMult;
   if(trend==1) sl-=noiseBuffer; else sl+=noiseBuffer;

   sl=EnforceMinStopDistance(entry,sl,trend!=1);
   sl=NormalizeDouble(sl,_Digits);
   // Risk % per trade tetap dijaga: lot dihitung dari SL AKTUAL (yg sudah dilebarkan),
   // jadi lot otomatis mengecil mengimbangi SL yang lebih longgar - risk $ per sinyal tidak berubah.
   double totalVolume=CalculateVolume(entry,sl);
   if(totalVolume<=0) { SetScanState("RISK_TOO_SMALL","Lot hasil perhitungan di bawah minimum broker"); return; }

   // ---- Jarak acuan TP: pakai SL DASAR (sblm buffer) kalau InpDecoupleTPFromSL=true, biar TP tetap dekat/tidak ikut melebar ----
   double tpBaseDistance=(InpDecoupleTPFromSL ? baseSLDistance : MathAbs(entry-sl));

   double legPercent[3]={InpTP1VolumePercent,InpTP2VolumePercent,InpTP3VolumePercent};
   double legRR[3]={InpTP1_RR,InpTP2_RR,InpTP3_RR};
   string legName[3]={"TP1","TP2","TP3"};

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   SetUniversalFillingMode(_Symbol);

   int opened=0; double openedVolume=0;
   int legsToTry=MathMin(3,maxLegsAllowed);
   for(int i=0;i<legsToTry;i++)
     {
      double legVolume=NormalizeVolume(totalVolume*legPercent[i]/100.0);
      if(legVolume<=0) { AppendEvent("LEG_SKIPPED",StringFormat("%s volume di bawah minimum broker",legName[i])); continue; }
      double tp=(trend==1 ? entry+tpBaseDistance*legRR[i] : entry-tpBaseDistance*legRR[i]);
      tp=EnforceMinStopDistance(entry,tp,trend==1);
      tp=NormalizeDouble(tp,_Digits);
      string cmt=InpTradeComment+"-"+signalMode+"-"+legName[i];
      bool ok=(trend==1 ? trade.Buy(legVolume,_Symbol,0,sl,tp,cmt) : trade.Sell(legVolume,_Symbol,0,sl,tp,cmt));
      if(ok)
        {
         opened++; openedVolume+=legVolume;
         AppendEvent("ORDER_OPENED",StringFormat("%s %s vol %.2f sl %.2f tp %.2f",legName[i],trend==1?"BUY":"SELL",legVolume,sl,tp));
        }
      else
        {
         AppendEvent("ORDER_FAILED",StringFormat("%s %s: %s",legName[i],trend==1?"BUY":"SELL",trade.ResultRetcodeDescription()));
        }
     }
   if(opened==0) { SetScanState("ORDER_FAILED","Semua leg order gagal dibuka"); return; }
   tradesToday++; lastSignal=(trend==1?"BUY_":"SELL_")+signalMode; lastSignalTime=TimeCurrent(); lastSignalMode=signalMode;
   SetScanState("POSITION_OPENED",StringFormat("%s; %d/3 leg terbuka; total vol %.2f; %s",lastSignal,opened,openedVolume,reason));
  }

// ======================== BREAKEVEN / PROTEKSI PROFIT ========================
// Setelah profit floating suatu posisi >= InpBreakEvenTriggerRR x SL DASAR (ATR x InpAtrSLMultiplier
// dihitung ulang dari ATR terkini), SL posisi digeser ke breakeven + buffer. Ini melindungi
// leg TP2/TP3 (yang jaraknya lebih jauh & lebih lama terbuka) supaya tidak balik jadi rugi
// gara-gara SL yang sudah dilebarkan oleh modul anti-stophunt di atas.
void ManageBreakEven()
  {
   if(!InpEnableBreakEven) return;
   double atr=GetBufferValue(hAtr);
   if(atr<=0) return;
   double baseSLDist=atr*InpAtrSLMultiplier;
   double triggerDist=baseSLDist*InpBreakEvenTriggerRR;
   if(triggerDist<=0) return;
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;

   // --- FIX v3.06: buffer breakeven wajib menutup spread & lolos min stop-level broker ---
   // Sebelumnya bufferPrice cuma InpBreakEvenBufferPoints*_Point tanpa cek apapun.
   // Di broker dgn quote presisi tinggi (_Point kecil) atau spread saat ini lebih
   // besar dari buffer, PositionModify() ditolak broker (invalid stops) -> SL lama
   // (masih di sisi rugi) tetap terpasang, dan EA tidak pernah tahu karena return
   // value-nya tidak dicek. Ini yang bikin sebagian posisi "breakeven lock"-nya
   // gagal kepasang dengan benar.
   long   stopLevelPts=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long   freezeLevelPts=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist=(double)MathMax(stopLevelPts,freezeLevelPts)*_Point;
   double spreadPrice=tick.ask-tick.bid;
   double bufferPrice=MathMax(InpBreakEvenBufferPoints*_Point, spreadPrice*InpSLSpreadBufferMult);
   bufferPrice=MathMax(bufferPrice, minDist+_Point);

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL=PositionGetDouble(POSITION_SL);
      double curTP=PositionGetDouble(POSITION_TP);

      if(type==POSITION_TYPE_BUY)
        {
         double profitDist=tick.bid-openPrice;
         if(profitDist<triggerDist) continue;
         double newSL=NormalizeDouble(openPrice+bufferPrice,_Digits);
         // pastikan jarak newSL ke harga skrg tidak melanggar stop-level broker
         if(tick.bid-newSL<minDist) newSL=NormalizeDouble(tick.bid-minDist-_Point,_Digits);
         if(newSL<=openPrice) continue; // kepepet minDist sampai di bawah open -> batalkan, jangan pasang SL yg jadi rugi
         if(curSL>0 && curSL>=newSL) continue; // sudah di breakeven/lebih baik, jangan digeser mundur
         if(!trade.PositionModify(ticket,newSL,curTP))
            AppendEvent("BREAK_EVEN_FAILED",StringFormat("ticket %I64u BUY: gagal geser SL ke %.2f (retcode %d, %s)",ticket,newSL,trade.ResultRetcode(),trade.ResultComment()));
         else
            AppendEvent("BREAK_EVEN",StringFormat("ticket %I64u BUY: SL digeser ke breakeven+buffer %.2f",ticket,newSL));
        }
      else if(type==POSITION_TYPE_SELL)
        {
         double profitDist=openPrice-tick.ask;
         if(profitDist<triggerDist) continue;
         double newSL=NormalizeDouble(openPrice-bufferPrice,_Digits);
         // pastikan jarak newSL ke harga skrg tidak melanggar stop-level broker
         if(newSL-tick.ask<minDist) newSL=NormalizeDouble(tick.ask+minDist+_Point,_Digits);
         if(newSL>=openPrice) continue; // kepepet minDist sampai di atas open -> batalkan, jangan pasang SL yg jadi rugi
         if(curSL>0 && curSL<=newSL) continue; // sudah di breakeven/lebih baik, jangan digeser mundur
         if(!trade.PositionModify(ticket,newSL,curTP))
            AppendEvent("BREAK_EVEN_FAILED",StringFormat("ticket %I64u SELL: gagal geser SL ke %.2f (retcode %d, %s)",ticket,newSL,trade.ResultRetcode(),trade.ResultComment()));
         else
            AppendEvent("BREAK_EVEN",StringFormat("ticket %I64u SELL: SL digeser ke breakeven+buffer %.2f",ticket,newSL));
        }
     }
  }

void TryEntry()
  {
   if(halted) { SetScanState("HALTED",haltReason); return; }
   if(currentMode!="H24_UNLIMITED" && InpMaxTradesPerDay>0 && tradesToday>=InpMaxTradesPerDay)
     { SetScanState("MAX_TRADES_REACHED",StringFormat("Sudah %d/%d trade hari ini (mode Default)",tradesToday,InpMaxTradesPerDay)); return; }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) { SetScanState("AUTOTRADING_OFF","AutoTrading dimatikan di terminal/EA"); return; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { SetScanState("TERMINAL_TRADE_DISABLED","Terminal tidak mengizinkan trading (cek koneksi/izin)"); return; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) { SetScanState("ACCOUNT_TRADE_DISABLED","Akun tidak mengizinkan trading (cek dgn broker)"); return; }
   ENUM_SYMBOL_TRADE_MODE tradeMode=(ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   if(tradeMode==SYMBOL_TRADE_MODE_DISABLED || tradeMode==SYMBOL_TRADE_MODE_CLOSEONLY)
     { SetScanState("SYMBOL_TRADE_DISABLED",StringFormat("Symbol %s tidak bisa open posisi baru saat ini",_Symbol)); return; }

   MqlTick spreadTick;
   if(!SymbolInfoTick(_Symbol,spreadTick) || spreadTick.ask<=0 || spreadTick.bid<=0)
     { SetScanState("PRICE_UNAVAILABLE","Tick bid/ask belum tersedia utk cek spread"); return; }
   double spreadPts=(spreadTick.ask-spreadTick.bid)/_Point;
   if(spreadPts>InpMaxSpreadPointsHardCap) { SetScanState("SPREAD_TOO_WIDE",StringFormat("Spread %.0f > hard cap %.0f points",spreadPts,InpMaxSpreadPointsHardCap)); return; }

   double atr=GetBufferValue(hAtr);
   if(atr<=0) { SetScanState("ATR_UNAVAILABLE","ATR belum siap"); return; }

   double spreadPrice=spreadPts*_Point;
   if(spreadPrice>atr*InpMaxSpreadATRPercent/100.0)
     {
      SetScanState("SPREAD_TOO_WIDE",StringFormat("Spread %.0f pts = %.1f%% dari ATR, maks %.1f%%",spreadPts,spreadPrice/atr*100.0,InpMaxSpreadATRPercent));
      return;
     }

   double atrBaseline=GetAtrBaseline(InpAtrBaselineBars);
   if(atrBaseline<=0) { SetScanState("ATR_BASELINE_UNAVAILABLE",StringFormat("Butuh %d bar history utk baseline ATR",InpAtrBaselineBars)); return; }
   double atrRatio=atr/atrBaseline;
   if(atrRatio<InpAtrMinMultiplier || atrRatio>InpAtrMaxMultiplier)
     {
      SetScanState("ATR_OUT_OF_RANGE",StringFormat("ATR %.0f pts = %.2fx median baseline (%.0f pts), butuh %.2fx-%.2fx",atr/_Point,atrRatio,atrBaseline/_Point,InpAtrMinMultiplier,InpAtrMaxMultiplier));
      return;
     }

   int trend=TrendDirection();
   int m1trend=M1TrendDirection();
   // Kalau trend M1 (cepat) sudah berlawanan dgn trend M15 (lamban), trend M15 dianggap "basi" utk
   // BREAKOUT/PULLBACK - JANGAN buka posisi baru searah trend M15 yg sudah tidak sesuai harga M1 saat ini.
   // Ini akar fix-nya: sebelumnya EA terus BUY selama M15 masih bullish walau M1 sudah jatuh tajam.
   bool m1Conflict=(InpRequireM1TrendAlign && trend!=0 && m1trend!=0 && m1trend!=trend);
   int alignedTrend=(m1Conflict?0:trend);

   // ---- Cari sinyal, urutan prioritas: BREAKOUT > PULLBACK > SR_REVERSAL > MOMENTUM_REVERSAL ----
   int    signalDir=0;
   string reason="";
   string signalMode="";
   double srInvalidationLevel=0;

   if(alignedTrend!=0 && IsBreakoutSignal(alignedTrend,atr,reason))
     {
      signalDir=alignedTrend; signalMode="BREAKOUT";
     }
   else if(alignedTrend!=0 && InpEnablePullback && IsPullbackSignal(alignedTrend,atr,reason))
     {
      signalDir=alignedTrend; signalMode="PULLBACK";
     }
   else if(InpEnableSRReversal)
     {
      int srDir=0; double srLevel=0; string srReason="";
      if(IsSRReversalSignal(atr,srDir,srLevel,srReason))
        {
         // InpSRRequireEmaAlign=false (default): reversal boleh melawan EMA trend, itu tujuannya.
         // InpSRRequireEmaAlign=true: reversal hanya dieksekusi kalau searah (atau EMA netral).
         if(!InpSRRequireEmaAlign || trend==0 || srDir==trend)
           {
            signalDir=srDir; reason=srReason; signalMode="SR_REVERSAL"; srInvalidationLevel=srLevel;
           }
         else
           reason="Reversal SR terdeteksi tapi ditahan InpSRRequireEmaAlign (melawan EMA trend)";
        }
      else
        {
         reason=(trend==0?"EMA trend belum jelas; ":"")+srReason;
         if(InpEnableMomentumReversal)
           {
            int momDir=0; string momReason="";
            if(IsMomentumReversalSignal(trend,atr,momDir,momReason))
              {
               signalDir=momDir; reason=momReason; signalMode="MOMENTUM_REVERSAL";
              }
            else
               reason=reason+"; "+momReason;
           }
        }
     }
   else if(InpEnableMomentumReversal)
     {
      int momDir=0; string momReason="";
      if(IsMomentumReversalSignal(trend,atr,momDir,momReason))
        {
         signalDir=momDir; reason=momReason; signalMode="MOMENTUM_REVERSAL";
        }
      else
         reason=(trend==0?"EMA trend belum jelas; ":"")+momReason;
     }
   else if(trend==0)
      reason="EMA trend belum jelas";

   if(m1Conflict && signalDir==0)
      reason="Trend M15 vs M1 berlawanan (M15="+(trend==1?"UP":"DOWN")+", M1="+(m1trend==1?"UP":"DOWN")+"), BREAKOUT/PULLBACK ditahan; "+reason;

   if(signalDir==0)
     {
      SetScanState("WAITING_SIGNAL",reason!=""?reason:"Menunggu breakout range, reversal di S/R, atau momentum reversal");
      return;
     }

   int posType=GetOurPositionType();

   bool isReversal=false;
   if((posType==POSITION_TYPE_BUY && signalDir==-1) || (posType==POSITION_TYPE_SELL && signalDir==1))
     {
      isReversal=true;
      if(!CloseAllOurPositions())
        {
         SetScanState("CLOSE_FAILED","Gagal menutup posisi lawan arah, order baru dibatalkan");
         return;
        }
      AppendEvent("POSITION_REVERSED",StringFormat("Tutup posisi %s, buka %s baru (%s)",PositionTypeLabel(posType),signalDir==1?"BUY":"SELL",signalMode));
     }

   // --- HARD CAP: jangan biarkan posisi aktif melebihi InpMaxOpenPositions ---
   // Dicek SETELAH reversal (kalau reversal, posisi lawan arah sudah ditutup di atas, jadi count sudah turun).
   // Kalau bukan reversal (nambah signal baru) & sudah di cap, tahan sinyal - jangan buka posisi baru sama sekali.
   int posCountNow=CountOurPositions();
   if(posCountNow>=InpMaxOpenPositions)
     {
      SetScanState("MAX_POSITIONS_REACHED",StringFormat("Sudah %d/%d posisi aktif, sinyal %s %s ditahan",posCountNow,InpMaxOpenPositions,signalDir==1?"BUY":"SELL",signalMode));
      return;
     }

   OpenMultiTPEntry(signalDir,atr,reason+(isReversal?" [REVERSAL]":""),signalMode,srInvalidationLevel,InpMaxOpenPositions-posCountNow);
  }

int OnInit()
  {
   if(InpRangeBars<2 || InpRiskPercent<=0 || InpAtrSLMultiplier<=0) return INIT_PARAMETERS_INCORRECT;
   if(InpTP1_RR<=0 || InpTP2_RR<=0 || InpTP3_RR<=0) return INIT_PARAMETERS_INCORRECT;
   double percentSum=InpTP1VolumePercent+InpTP2VolumePercent+InpTP3VolumePercent;
   if(percentSum<95.0 || percentSum>105.0) return INIT_PARAMETERS_INCORRECT;

   if(InpTrendEmaFast<=0 || InpTrendEmaSlow<=0 || InpTrendEmaFast>=InpTrendEmaSlow)
      return INIT_PARAMETERS_INCORRECT;
   if(InpAtrPeriod<=0 || InpAtrBaselineBars<2) return INIT_PARAMETERS_INCORRECT;
   if(InpAtrMinMultiplier<=0 || InpAtrMaxMultiplier<=InpAtrMinMultiplier) return INIT_PARAMETERS_INCORRECT;
   if(InpMaxSpreadATRPercent<=0 || InpMaxSpreadPointsHardCap<=0) return INIT_PARAMETERS_INCORRECT;
   if(InpMaxDailyLossPercent<=0 || InpMaxLotSize<=0) return INIT_PARAMETERS_INCORRECT;
   if(InpMaxDailyProfitPercent<0 || InpMaxTradesPerDay<0) return INIT_PARAMETERS_INCORRECT;
   if(InpMaxOpenPositions<=0) return INIT_PARAMETERS_INCORRECT;
   if(InpCommandPollIntervalSec<=0) return INIT_PARAMETERS_INCORRECT;
   if(InpDeviationPoints<0) return INIT_PARAMETERS_INCORRECT;
   if(InpCloseExtremePercent<0 || InpCloseExtremePercent>100) return INIT_PARAMETERS_INCORRECT;

   if(InpSRFractalDepth<1) return INIT_PARAMETERS_INCORRECT;
   if(InpSRLookbackBars<InpSRFractalDepth*4) return INIT_PARAMETERS_INCORRECT;
   if(InpSRMaxLevels<1) return INIT_PARAMETERS_INCORRECT;
   if(InpSRZoneATRMult<=0) return INIT_PARAMETERS_INCORRECT;
   if(InpSRMinTouches<1) return INIT_PARAMETERS_INCORRECT;
   if(InpSRRejectionWickPercent<0 || InpSRRejectionWickPercent>100) return INIT_PARAMETERS_INCORRECT;
   if(InpSRRecalcIntervalSec<=0) return INIT_PARAMETERS_INCORRECT;
   if(InpSRMinRangeATR<0) return INIT_PARAMETERS_INCORRECT;

   if(InpPullbackEmaPeriod<=0 || InpPullbackTouchATR<=0 || InpPullbackMinBodyATR<=0) return INIT_PARAMETERS_INCORRECT;

   if(InpM1TrendEmaFast<=0 || InpM1TrendEmaSlow<=0 || InpM1TrendEmaFast>=InpM1TrendEmaSlow) return INIT_PARAMETERS_INCORRECT;
   if(InpMomentumMinBodyATR<=0 || InpMomentumConfirmBars<1) return INIT_PARAMETERS_INCORRECT;

   if(InpSLNoiseBufferATR<0 || InpSLSpreadBufferMult<0) return INIT_PARAMETERS_INCORRECT;
   if(InpEnableBreakEven && (InpBreakEvenTriggerRR<=0 || InpBreakEvenBufferPoints<0)) return INIT_PARAMETERS_INCORRECT;

   SymbolSelect(_Symbol,true);
   hEmaFast=iMA(_Symbol,InpTrendTF,InpTrendEmaFast,0,MODE_EMA,PRICE_CLOSE);
   hEmaSlow=iMA(_Symbol,InpTrendTF,InpTrendEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   hAtr=iATR(_Symbol,InpEntryTF,InpAtrPeriod);
   hEmaPullback=iMA(_Symbol,InpEntryTF,InpPullbackEmaPeriod,0,MODE_EMA,PRICE_CLOSE);
   hEmaM1Fast=iMA(_Symbol,InpEntryTF,InpM1TrendEmaFast,0,MODE_EMA,PRICE_CLOSE);
   hEmaM1Slow=iMA(_Symbol,InpEntryTF,InpM1TrendEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE || hAtr==INVALID_HANDLE || hEmaPullback==INVALID_HANDLE
      || hEmaM1Fast==INVALID_HANDLE || hEmaM1Slow==INVALID_HANDLE) return INIT_FAILED;
   indicatorsReady=true; ResetDay(); EventSetTimer(1);
   SetScanState("STARTING","Range Breakout M1 MultiTP siap; menunggu candle baru");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(hEmaFast!=INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow!=INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hAtr!=INVALID_HANDLE) IndicatorRelease(hAtr);
   if(hEmaPullback!=INVALID_HANDLE) IndicatorRelease(hEmaPullback);
   if(hEmaM1Fast!=INVALID_HANDLE) IndicatorRelease(hEmaM1Fast);
   if(hEmaM1Slow!=INVALID_HANDLE) IndicatorRelease(hEmaM1Slow);
  }

void OnTimer()
  {
   CheckNewDay(); PollCommandFile(); WriteStatus();
   if(lastTickTime>0 && TimeCurrent()-lastTickTime>60) SetScanState("NO_TICK","Tidak ada tick baru lebih dari 60 detik");
  }

void OnTick()
  {
   lastTickTime=TimeCurrent(); CheckNewDay();
   if(InpEnableSRReversal)
     {
      RecalcSRLevels();
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      if(bid>0) GetNearestSR(bid,lastResistance,lastSupport);
     }
   WriteStatus();
   ManageBreakEven();
   if(dayStartEquity>0 && (AccountInfoDouble(ACCOUNT_EQUITY)-dayStartEquity)/dayStartEquity*100.0<=-InpMaxDailyLossPercent)
     { halted=true; haltReason=StringFormat("Daily loss limit %.2f%% tercapai",InpMaxDailyLossPercent); SetScanState("HALTED",haltReason); return; }
   if(InpMaxDailyProfitPercent>0 && dayStartEquity>0 && (AccountInfoDouble(ACCOUNT_EQUITY)-dayStartEquity)/dayStartEquity*100.0>=InpMaxDailyProfitPercent)
     { halted=true; haltReason=StringFormat("Daily profit target %.2f%% tercapai",InpMaxDailyProfitPercent); SetScanState("HALTED",haltReason); return; }
   datetime bar=iTime(_Symbol,InpEntryTF,0);
   if(bar<=0) { SetScanState("BAR_DATA_UNAVAILABLE",StringFormat("Data %s belum tersedia",EnumToString(InpEntryTF))); return; }
   if(bar==lastBarTime) { SetScanState("WAITING_NEW_BAR",StringFormat("Menunggu candle %s baru",EnumToString(InpEntryTF))); return; }
   lastBarTime=bar;
   TryEntry();
  }