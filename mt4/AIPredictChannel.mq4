//+------------------------------------------------------------------+
//|                                            AIPredictChannel.mq4  |
//|  AI Price-Channel Predictor for CHART//SCOPE (MetaTrader 4)      |
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

void OnTick() { /* drawing driven by timer */ }

string BuildPayload()
{
   int need = MathMin(InpCandles, Bars);
   if(need < 30) return "";
   string json = "{\"symbol\":\"" + Symbol() + "\",\"horizon\":" + IntegerToString(InpHorizonBars) +
                 ",\"ai\":" + (InpUseAi ? "true" : "false") + ",\"candles\":[";
   for(int i = need - 1; i >= 0; i--)   // oldest -> newest
   {
      if(i < need - 1) json += ",";
      json += StringFormat("{\"time\":%d,\"open\":%.8f,\"high\":%.8f,\"low\":%.8f,\"close\":%.8f,\"volume\":%.2f}",
                           (long)Time[i], Open[i], High[i], Low[i], Close[i], (double)Volume[i]);
   }
   json += "]}";
   return json;
}

string JsonGet(const string src, const string key)
{
   string pat = "\"" + key + "\":";
   int p = StringFind(src, pat);
   if(p < 0) return "";
   p += StringLen(pat);
   while(p < StringLen(src) && StringGetChar(src, p) == ' ') p++;
   if(p >= StringLen(src)) return "";
   int c = StringGetChar(src, p);
   if(c == '"')
   {
      int e = StringFind(src, "\"", p + 1);
      if(e < 0) return "";
      return StringSubstr(src, p + 1, e - p - 1);
   }
   int e = p;
   while(e < StringLen(src))
   {
      int ch = StringGetChar(src, e);
      if(ch == ',' || ch == '}' || ch == ']') break;
      e++;
   }
   return StringSubstr(src, p, e - p);
}

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
      ArrayResize(times, n + 1); ArrayResize(prices, n + 1);
      times[n]  = StrToDouble(StringSubstr(body, tp + 4, te - tp - 4));
      prices[n] = StrToDouble(StringSubstr(body, pp + 4, pe - pp - 4));
      n++;
      pos = MathMax(pe, te) + 1;
   }
   return n;
}

void DrawLine(const string name, const double &times[], const double &prices[], const int count, const color clr, const int style)
{
   if(count < 2) return;
   ObjectDelete(name);
   ObjectCreate(name, OBJ_TREND, 0, (datetime)times[0], prices[0], (datetime)times[count - 1], prices[count - 1]);
   ObjectSet(name, OBJPROP_COLOR, clr);
   ObjectSet(name, OBJPROP_WIDTH, InpLineWidth);
   ObjectSet(name, OBJPROP_STYLE, style);
   ObjectSet(name, OBJPROP_RAY, false);
   ObjectSet(name, OBJPROP_SELECTABLE, false);
   ObjectSet(name, OBJPROP_HIDDEN, true);
}

void DrawChannelFill(const double &ut[], const double &up[], const double &lt[], const double &lp[], const int count)
{
   if(!InpFillChannel || count < 2) return;
   string name = "AIPC_FILL";
   ObjectDelete(name);
   ObjectCreate(name, OBJ_TRIANGLE, 0, (datetime)ut[0], up[0], (datetime)ut[count - 1], up[count - 1]);
   ObjectMove(name, 2, (datetime)lt[count - 1], lp[count - 1]);
   ObjectSet(name, OBJPROP_COLOR, InpColorMid);
   ObjectSet(name, OBJPROP_BACK, true);
   ObjectSet(name, OBJPROP_SELECTABLE, false);
   ObjectSet(name, OBJPROP_HIDDEN, true);
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
                    " (add URL in Tools>Options>Expert Advisors>Allow WebRequest)";
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
   WindowRedraw();

   if(InpShowPanel)
   {
      string txt = "CHART//SCOPE · AI Channel\n";
      txt += "Symbol: " + Symbol() + "  TF: M" + IntegerToString(Period() ) + "\n";
      txt += "Method: " + method + "   Bias: " + bias + "   Confidence: " + conf + "%\n";
      txt += reason + "\n";
      txt += "Analysis only — no trade execution, no profit guarantee.";
      Comment(txt);
   }
   g_lastError = "";
}
