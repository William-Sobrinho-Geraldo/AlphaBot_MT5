//+------------------------------------------------------------------+
//|                                                     Signals.mqh  |
//|                                               AlphaBot Trading  |
//|                                                                  |
//| Requisito 2 - Módulo de Sinais (SMA 200 + ADX 14 + Price Action) |
//+------------------------------------------------------------------+
#property copyright "AlphaBot Trading"
#property version   "1.00"

#ifndef __ALPHABOT_SIGNALS_MQH__
#define __ALPHABOT_SIGNALS_MQH__

//+------------------------------------------------------------------+
//| Parâmetros fixos dos indicadores                                 |
//+------------------------------------------------------------------+
#define SIGNALS_MA_PERIOD    200
#define SIGNALS_ADX_PERIOD   14
#define SIGNALS_ADX_MINIMO   25.0
#define SIGNALS_PINBAR_RATIO 2.5

//+------------------------------------------------------------------+
//| Handles globais dos indicadores                                  |
//+------------------------------------------------------------------+
int g_handle_ma  = INVALID_HANDLE;
int g_handle_adx = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Cria e valida os handles dos indicadores no timeframe atual.     |
//| Retorna false (com log de erro) se qualquer handle falhar.       |
//+------------------------------------------------------------------+
bool InitSignals()
  {
   g_handle_ma=iMA(_Symbol, PERIOD_CURRENT, SIGNALS_MA_PERIOD, 0, MODE_SMA, PRICE_CLOSE);
   if(g_handle_ma==INVALID_HANDLE)
     {
      Print("AlphaBot - ERRO: falha ao criar handle da SMA ",
            SIGNALS_MA_PERIOD, " (erro ", GetLastError(), ").");
      return(false);
     }

   g_handle_adx=iADX(_Symbol, PERIOD_CURRENT, SIGNALS_ADX_PERIOD);
   if(g_handle_adx==INVALID_HANDLE)
     {
      Print("AlphaBot - ERRO: falha ao criar handle do ADX ",
            SIGNALS_ADX_PERIOD, " (erro ", GetLastError(), ").");
      IndicatorRelease(g_handle_ma);
      g_handle_ma=INVALID_HANDLE;
      return(false);
     }

   Print("AlphaBot - Indicadores inicializados (SMA ", SIGNALS_MA_PERIOD,
         " | ADX ", SIGNALS_ADX_PERIOD, ") no timeframe ",
         EnumToString(PERIOD_CURRENT), ".");
   return(true);
  }

//+------------------------------------------------------------------+
//| Libera os handles dos indicadores.                               |
//+------------------------------------------------------------------+
void ReleaseSignals()
  {
   if(g_handle_ma!=INVALID_HANDLE)
     {
      IndicatorRelease(g_handle_ma);
      g_handle_ma=INVALID_HANDLE;
     }

   if(g_handle_adx!=INVALID_HANDLE)
     {
      IndicatorRelease(g_handle_adx);
      g_handle_adx=INVALID_HANDLE;
     }
  }

//+------------------------------------------------------------------+
//| Verifica se candles[0] (índice 1) forma Engolfo de Alta.          |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(const MqlRates &atual, const MqlRates &anterior)
  {
   bool atualAlta    = (atual.close > atual.open);
   bool anteriorBaixa= (anterior.close < anterior.open);

   if(!atualAlta || !anteriorBaixa)
      return(false);

   return(atual.open <= anterior.close && atual.close >= anterior.open);
  }

//+------------------------------------------------------------------+
//| Verifica Pin Bar de Alta: pavio inferior >= 2.5x o corpo.         |
//+------------------------------------------------------------------+
bool IsBullishPinBar(const MqlRates &candle)
  {
   double corpo     = MathAbs(candle.close - candle.open);
   double pavioBaixo= MathMin(candle.open, candle.close) - candle.low;

   if(pavioBaixo <= 0.0)
      return(false);

   return(pavioBaixo >= SIGNALS_PINBAR_RATIO * corpo);
  }

//+------------------------------------------------------------------+
//| Sinal de compra no timeframe atual.                              |
//| Regra 1: fechamento atual > SMA 200                              |
//| Regra 2: ADX principal > 25                                      |
//| Regra 3: candle[1] = Engolfo de Alta OU Pin Bar de Alta          |
//+------------------------------------------------------------------+
bool CheckBuySignal()
  {
   if(g_handle_ma==INVALID_HANDLE || g_handle_adx==INVALID_HANDLE)
     {
      Print("AlphaBot - ERRO: CheckBuySignal chamada sem handles válidos. ",
            "InitSignals() deve ser executada em OnInit().");
      return(false);
     }

   if(Bars(_Symbol, PERIOD_CURRENT) < SIGNALS_MA_PERIOD + 2)
     {
      Print("AlphaBot - AVISO: barras insuficientes (", Bars(_Symbol, PERIOD_CURRENT),
            ") para SMA ", SIGNALS_MA_PERIOD, ".");
      return(false);
     }

//--- SMA 200 (buffer 0), valor atual
   double sma[];
   if(CopyBuffer(g_handle_ma, 0, 0, 1, sma) != 1)
     {
      Print("AlphaBot - ERRO: CopyBuffer(SMA) retornou ", GetLastError(), ".");
      return(false);
     }

//--- ADX linha principal (buffer 0), valor atual
   double adx[];
   if(CopyBuffer(g_handle_adx, 0, 0, 1, adx) != 1)
     {
      Print("AlphaBot - ERRO: CopyBuffer(ADX) retornou ", GetLastError(), ".");
      return(false);
     }

//--- Fechamento atual (índice 0)
   double fechamento[];
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, 1, fechamento) != 1)
     {
      Print("AlphaBot - ERRO: CopyClose retornou ", GetLastError(), ".");
      return(false);
     }

//--- Últimos 2 candles fechados: índices 1 e 2
//--- rates[0] = candle[1] | rates[1] = candle[2]
   MqlRates rates[];
   if(CopyRates(_Symbol, PERIOD_CURRENT, 1, 2, rates) != 2)
     {
      Print("AlphaBot - ERRO: CopyRates retornou ", GetLastError(), ".");
      return(false);
     }

//--- Regra 1: preço de fechamento atual acima da SMA 200
   bool regra1 = (fechamento[0] > sma[0]);

//--- Regra 2: força de tendência (ADX principal acima de 25)
   bool regra2 = (adx[0] > SIGNALS_ADX_MINIMO);

//--- Regra 3: gatilho de price action no candle[1]
   bool regra3 = (IsBullishEngulfing(rates[0], rates[1]) || IsBullishPinBar(rates[0]));

   if(regra1 && regra2 && regra3)
     {
      Print("AlphaBot - CheckBuySignal: SMA=", DoubleToString(sma[0], _Digits),
            " | ADX=", DoubleToString(adx[0], 1),
            " | Close=", DoubleToString(fechamento[0], _Digits));
      return(true);
     }

   return(false);
  }

#endif // __ALPHABOT_SIGNALS_MQH__
//+------------------------------------------------------------------+
