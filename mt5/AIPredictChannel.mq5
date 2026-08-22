//+------------------------------------------------------------------+
//|                                            AIPredictChannel.mq5  |
//|  AI Price-Channel Predictor for CHART//SCOPE                     |
//|  Sends recent candles to the analysis server, receives an        |
//|  AI/statistical regression channel and draws it on the chart.    |
//|  NO trade execution. Analysis/visualisation only.                |
//+------------------------------------------------------------------+
#property copyright "price-action-analyst"
#property version   "1.00"
#property strict

input string InpServerUrl     = "https://YOUR-DOMAIN/api/predict/channel"; // Server endpoint
input string InpBridgeSecret  = "";            // Must match MT_BRIDGE_SECRET on server
input int    InpCandles       = 200;           // Candles to send (30..500)
input int    InpHorizonBars   = 20;            // Forecast horizon (10/20/30/60)
input bool   InpUseAi         = true;          // Ask server to refine with AI
input int    InpRefreshSec    = 15;            // Refresh interval (seconds)
input color  InpColorMid      = clrGold;       // Mid line color
input color  InpColorUpper    = clrDodgerBlue; // Upper line color
input color  InpColorLower    = clrTomato;     // Lower line color
input int    InpLineWidth     = 2;             // Line width
input bool   InpFillChannel   = true;          // Fill channel area
input bool   InpShowPanel     = true;          // Show info panel (Comment)

datetime g_lastRun = 0;
string   g_lastError = "";

int OnInit()
{
   if(InpCandles < 30 || InpCandles > 500) { Print("InpCandles must be 30..500"); return INIT_PARAMETERS_INCORRECT; }
   if(StringLen(InpServerUrl) < 12)        { Print("Set InpServerUrl"); return INIT_PARAMETERS_INCORRECT; }
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); ObjectsDeleteAll(0, "AIPC_"); Comment(""); }

void OnTimer()
{
   if(TimeCurrent() - g_lastRun < InpRefreshSec) return;
   g_lastRun = TimeCurrent();
   RequestAndDraw();
}

void OnTick() { /* drawing driven by timer to respect WebRequest limits */ }

string BuildPayload()
{
   int need = MathMin(InpCandles, Bars(_Symbol, PERIOD_CURRENT));
   if(need < 30) return "";
   string json = "{\"symbol\":\"" + _Symbol + "\",\"horizon\":" + IntegerToString(InpHorizonBars) +
                 ",\"ai\":" + (InpUseAi ? "true" : "false") + ",\"candles\":[";
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, PERIOD_CURRENT, 0, need, rates);
   if(copied < 30) return "";
   for(int i = 0; i < copied; i++)
   {
      if(i > 0) json += ",";
      json += StringFormat("{\"time\":%d,\"open\":%.8f,\"high\":%.8f,\"low\":%.8f,\"close\":%.8f,\"volume\":%.2f}",
                           (long)rates[i].time, rates[i].open, rates[i].high, rates[i].low, rates[i].close,
                           (double)rates[i].tick_volume);
   }
   json += "]}";
   return json;
}

// Minimal JSON field extractor for flat numeric/string fields of the response.
string JsonGet(const string src, const string key)
{
   string pat = "\"" + key + "\":";
   int p = StringFind(src, pat);
   if(p < 0) return "";
   p += StringLen(pat);
   while(p < StringLen(src) && (StringGetCharacter(src, p) == ' ')) p++;
   if(p >= StringLen(src)) return "";
   ushort c = StringGetCharacter(src, p);
   if(c == '"')
   {
      int e = StringFind(src, "\"", p + 1);
      if(e < 0) return "";
      return StringSubstr(src, p + 1, e - p - 1);
   }
   int e = p;
   while(e < StringLen(src))
   {
      ushort ch = StringGetCharacter(src, e);
      if(ch == ',' || ch == '}' || ch == ']') break;
      e++;
   }
   return StringSubstr(src, p, e - p);
}

// Extract arrays like "mid":[{"t":123,"p":1.23},...] as parallel t|p pairs.
int ExtractPoints(const string src, const string key, double &times[], double &prices[])
{
   string pat = "\"" + key + "\":[";
   int start = StringFind(src, pat);
   if(start < 0) return 0;
   start += StringLen(pat);
   int end = StringFind(src, "]", start);
   if(end < 0) return 0;
   string body = StringSubstr(src, start, end - start);
   int n = 0;
   ArrayResize(times, 0); ArrayResize(prices, 0);
   int pos = 0;
   while(true)
   {
      int tp = StringFind(body, "\"t\":", pos);
      int pp = StringFind(body, "\"p\":", pos);
      if(tp < 0 || pp < 0) break;
      int te = StringFind(body, ",", tp);
      int pe = StringFind(body, "}", pp);
      if(te < 0 || pe < 0) break;
      string tv = StringSubstr(body, tp + 4, te - tp - 4);
      string pv = StringSubstr(body, pp + 4, pe - pp - 4);
      ArrayResize(times, n + 1); ArrayResize(prices, n + 1);
      times[n] = StringToDouble(tv);
      prices[n] = StringToDouble(pv);
      n++;
      pos = MathMax(pe, te) + 1;
   }
   return n;
}

void DrawLine(const string name, const double &times[], const double &prices[], const int count, const color clr, const ENUM_LINE_STYLE style)
{
   if(count < 2) return;
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TREND, 0, (datetime)times[0], prices[0], (datetime)times[count - 1], prices[count - 1]);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void DrawChannelFill(const double &ut[], const double &up[], const double &lt[], const double &lp[], const int count)
{
   if(!InpFillChannel || count < 2) return;
   string name = "AIPC_FILL";
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TRIANGLE, 0, (datetime)ut[0], up[0], (datetime)ut[count - 1], up[count - 1], (datetime)lt[count - 1], lp[count - 1]);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpColorMid);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void RequestAndDraw()
{
   string payload = BuildPayload();
   if(payload == "") { g_lastError = "not enough bars"; return; }

   string headers = "Content-Type: application/json\r\n";
   if(StringLen(InpBridgeSecret) > 0) headers += "x-bridge-secret: " + InpBridgeSecret + "\r\n";
   char post[]; StringToCharArray(payload, post, 0, StringLen(payload), CP_UTF8);
   char result[]; string resultHeaders;

   ResetLastError();
   int status = WebRequest("POST", InpServerUrl, headers, 15000, post, result, resultHeaders);
   if(status == -1)
   {
      g_lastError = "WebRequest failed err=" + IntegerToString(GetLastError()) +
                    " (add URL to Tools>Options>Expert Advisors>Allow WebRequest)";
      Print(g_lastError);
      return;
   }
   string response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(status != 200)
   {
      g_lastError = "HTTP " + IntegerToString(status) + ": " + StringSubstr(response, 0, 180);
      Print(g_lastError);
      return;
   }

   double mt[], mp[], ut[], up[], lt[], lp[];
   int mN = ExtractPoints(response, "mid", mt, mp);
   int uN = ExtractPoints(response, "upper", ut, up);
   int lN = ExtractPoints(response, "lower", lt, lp);
   if(mN < 2 || uN < 2 || lN < 2) { g_lastError = "bad response shape"; Print(g_lastError); return; }

   DrawLine("AIPC_MID",   mt, mp, mN, InpColorMid,   STYLE_SOLID);
   DrawLine("AIPC_UPPER", ut, up, uN, InpColorUpper, STYLE_DOT);
   DrawLine("AIPC_LOWER", lt, lp, lN, InpColorLower, STYLE_DOT);
   DrawChannelFill(ut, up, lt, lp, MathMin(uN, lN));

   string bias   = JsonGet(response, "bias");
   string conf   = JsonGet(response, "confidence");
   string method = JsonGet(response, "method");
   string reason = JsonGet(response, "reason");
   ChartRedraw(0);

   if(InpShowPanel)
   {
      string txt = "CHART//SCOPE · AI Channel\n";
      txt += "Symbol: " + _Symbol + "  TF: M" + IntegerToString(PeriodSeconds() / 60) + "\n";
      txt += "Method: " + method + "   Bias: " + bias + "   Confidence: " + conf + "%\n";
      txt += reason + "\n";
      txt += "Analysis only — no trade execution, no profit guarantee.";
      Comment(txt);
   }
   g_lastError = "";
}
