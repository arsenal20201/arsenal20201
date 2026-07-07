//+------------------------------------------------------------------+
//| ExportRatesCSV.mq5                                               |
//| Exports M1 history of the current chart symbol to a CSV file so  |
//| the offline backtester (backtester/smc_backtest.py) can be run   |
//| against YOUR broker's exact feed.                                |
//|                                                                  |
//| How to use:                                                      |
//|   1. Copy this file to MQL5/Scripts in your MT5 data folder and  |
//|      compile it in MetaEditor (F7).                              |
//|   2. Open an XAUUSD chart, any timeframe.                        |
//|   3. Drag the script onto the chart. Set DaysBack (default 400). |
//|   4. The file appears in <MT5 Data Folder>/MQL5/Files/           |
//|      e.g. XAUUSD_M1_export.csv                                   |
//|   5. Upload that CSV to the chat or commit it to the repo as     |
//|      backtester/data/XAUUSD_M1.csv (the backtester reads MT5's   |
//|      'YYYY.MM.DD HH:MM' timestamps directly; gzip is optional).  |
//|                                                                  |
//| NOTE: MT5 server time is usually NOT UTC (often UTC+2/+3). For   |
//| session-filter accuracy set ServerUTCOffsetHours to your         |
//| broker's offset so timestamps are converted to UTC on export.    |
//+------------------------------------------------------------------+
#property copyright "arsenal20201"
#property version   "1.00"
#property script_show_inputs

input int DaysBack             = 400;   // how many calendar days of M1 history
input int ServerUTCOffsetHours = 0;     // broker server time minus UTC, in hours

void OnStart()
  {
   string   symbol = _Symbol;
   datetime to     = TimeCurrent();
   datetime from   = to - (datetime)DaysBack * 86400;

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(symbol, PERIOD_M1, from, to, rates);
   if(copied <= 0)
     {
      Print("CopyRates failed: ", GetLastError(),
            ". Scroll the M1 chart back to force history download, then rerun.");
      return;
     }

   string fname = symbol + "_M1_export.csv";
   int fh = FileOpen(fname, FILE_WRITE | FILE_ANSI | FILE_TXT);
   if(fh == INVALID_HANDLE)
     {
      Print("FileOpen failed: ", GetLastError());
      return;
     }

   FileWriteString(fh, "timestamp,open,high,low,close,volume\n");
   int offset = ServerUTCOffsetHours * 3600;
   for(int i = 0; i < copied; i++)
     {
      datetime t_utc = rates[i].time - offset;
      FileWriteString(fh, StringFormat("%s,%.3f,%.3f,%.3f,%.3f,%d\n",
                      TimeToString(t_utc, TIME_DATE | TIME_MINUTES),
                      rates[i].open, rates[i].high, rates[i].low,
                      rates[i].close, (int)rates[i].tick_volume));
     }
   FileClose(fh);
   PrintFormat("Exported %d M1 bars of %s to MQL5\\Files\\%s (%s .. %s)",
               copied, symbol, fname,
               TimeToString(rates[0].time), TimeToString(rates[copied-1].time));
  }
//+------------------------------------------------------------------+
