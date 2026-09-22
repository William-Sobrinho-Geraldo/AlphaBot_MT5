//+------------------------------------------------------------------+
//|                                              AlphaBot_MT5.mq5     |
//|                                                AlphaBot Trading  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "AlphaBot Trading"
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Parâmetros Operacionais - Interface nativa do MT5                |
//+------------------------------------------------------------------+
input group "=== AlphaBot - Parâmetros Operacionais ==="
input double InpLoteInicial     = 0.01; // Lote Inicial
input int    InpPassoGridPontos = 200;  // Passo do Grid (pontos)
input int    InpStopLossGlobal  = 300;  // Stop Loss Global (pontos)

input group "=== AlphaBot - Filtros de Tendência ==="
input int    InpMaPeriod        = 200;  // Período da Média Móvel (SMA)
input int    InpAdxPeriod       = 14;   // Período do ADX
input double InpAdxMinimo       = 25.0; // ADX mínimo p/ tendência forte
input double InpPinBarRatio     = 2.5;  // Corpo x Pavio (Pin Bar)

input group "=== AlphaBot - Execução de Ordens ==="
input long   InpMagicNumber    = 123456; // Magic Number do robô

//+------------------------------------------------------------------+
//| Handles globais dos indicadores e objeto de trade                |
//+------------------------------------------------------------------+
int    g_handle_sma = INVALID_HANDLE;
int    g_handle_adx = INVALID_HANDLE;
CTrade trade;

//+------------------------------------------------------------------+
//| Cria e valida os handles dos indicadores no timeframe atual.     |
//+------------------------------------------------------------------+
bool InitIndicadores()
  {
   g_handle_sma=iMA(_Symbol, PERIOD_CURRENT, InpMaPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(g_handle_sma==INVALID_HANDLE)
     {
      Print("AlphaBot - ERRO: falha ao criar handle da SMA ",
            InpMaPeriod, " (erro ", GetLastError(), ").");
      return(false);
     }

   g_handle_adx=iADX(_Symbol, PERIOD_CURRENT, InpAdxPeriod);
   if(g_handle_adx==INVALID_HANDLE)
     {
      Print("AlphaBot - ERRO: falha ao criar handle do ADX ",
            InpAdxPeriod, " (erro ", GetLastError(), ").");
      IndicatorRelease(g_handle_sma);
      g_handle_sma=INVALID_HANDLE;
      return(false);
     }

   Print("AlphaBot - Indicadores inicializados (SMA ", InpMaPeriod,
         " | ADX ", InpAdxPeriod, ") no timeframe ",
         EnumToString(PERIOD_CURRENT), ".");
   return(true);
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Guard de Segurança: verifica o modo de margem da conta
   ENUM_ACCOUNT_MARGIN_MODE margin_mode=(ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   if(margin_mode==ACCOUNT_MARGIN_MODE_RETAIL_NETTING ||
      margin_mode==ACCOUNT_MARGIN_MODE_EXCHANGE)
     {
      Alert("AlphaBot - ERRO: Modo de margem '"+
            EnumToString(margin_mode)+
            "' detectado. Este robô exige conta no modo HEDGE. Robô NÃO carregado.");
      Print("AlphaBot - OnInit abortado: conta incompatível ("+
            EnumToString(margin_mode)+").");
      return(INIT_FAILED);
     }

//--- Requisito 2: criação e validação dos handles dos indicadores
   if(!InitIndicadores())
     {
      Alert("AlphaBot - ERRO: falha ao inicializar os indicadores. Robô NÃO carregado.");
      return(INIT_FAILED);
     }

//--- Configuração do objeto de execução (Requisito 3)
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);

   if(!trade.SetTypeFillingBySymbol(_Symbol))
      Print("AlphaBot - AVISO: não foi possível definir o modo de preenchimento (filling) para ",
            _Symbol, " (erro ", GetLastError(), ").");

   Print("AlphaBot - Execução configurada: MagicNumber=", InpMagicNumber, ".");

   Print("AlphaBot - Inicializado com sucesso: conta em modo HEDGE.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_handle_sma!=INVALID_HANDLE)
     {
      IndicatorRelease(g_handle_sma);
      g_handle_sma=INVALID_HANDLE;
     }

   if(g_handle_adx!=INVALID_HANDLE)
     {
      IndicatorRelease(g_handle_adx);
      g_handle_adx=INVALID_HANDLE;
     }

   Print("AlphaBot - Desinicializado. Código de motivo: ", reason);
  }

//+------------------------------------------------------------------+
//| Engolfo de Alta: candle[0] engole o corpo do candle[1].          |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(const MqlRates &atual, const MqlRates &anterior)
  {
   bool atualAlta     = (atual.close > atual.open);
   bool anteriorBaixa = (anterior.close < anterior.open);

   if(!atualAlta || !anteriorBaixa)
      return(false);

   return(atual.open <= anterior.close && atual.close >= anterior.open);
  }

//+------------------------------------------------------------------+
//| Pin Bar de Alta: pavio inferior >= 2.5x o corpo (rejeição).      |
//+------------------------------------------------------------------+
bool IsBullishPinBar(const MqlRates &candle)
  {
   double corpo      = MathAbs(candle.close - candle.open);
   double pavioBaixo = MathMin(candle.open, candle.close) - candle.low;

   if(pavioBaixo <= 0.0)
      return(false);

   return(pavioBaixo >= InpPinBarRatio * corpo);
  }

//+------------------------------------------------------------------+
//| Requisito 2 - Módulo de Sinais                                   |
//| Regra 1: fechamento atual > SMA 200                              |
//| Regra 2: ADX principal > 25                                      |
//| Regra 3: candle[1] = Engolfo de Alta OU Pin Bar de Alta          |
//+------------------------------------------------------------------+
bool CheckBuySignal()
  {
   if(g_handle_sma==INVALID_HANDLE || g_handle_adx==INVALID_HANDLE)
     {
      Print("AlphaBot - ERRO: CheckBuySignal sem handles válidos. ",
            "InitIndicadores() deve ser executada em OnInit().");
      return(false);
     }

   if(Bars(_Symbol, PERIOD_CURRENT) < InpMaPeriod + 2)
     {
      Print("AlphaBot - AVISO: barras insuficientes (",
            Bars(_Symbol, PERIOD_CURRENT), ") para SMA ", InpMaPeriod, ".");
      return(false);
     }

//--- SMA 200 (buffer 0) - valor atual
   double sma[];
   if(CopyBuffer(g_handle_sma, 0, 0, 1, sma) != 1)
     {
      Print("AlphaBot - ERRO: CopyBuffer(SMA) retornou ", GetLastError(), ".");
      return(false);
     }

//--- ADX linha principal (buffer 0) - valor atual
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
   bool regra1=(fechamento[0] > sma[0]);

//--- Regra 2: força de tendência (ADX principal acima de 25)
   bool regra2=(adx[0] > InpAdxMinimo);

//--- Regra 3: gatilho de price action no candle[1]
   bool regra3=(IsBullishEngulfing(rates[0], rates[1]) || IsBullishPinBar(rates[0]));

   if(regra1 && regra2 && regra3)
     {
      Print("AlphaBot - CheckBuySignal: SMA=", DoubleToString(sma[0], _Digits),
            " | ADX=", DoubleToString(adx[0], 1),
            " | Close=", DoubleToString(fechamento[0], _Digits));
      return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Verifica se já existe posição aberta deste EA (símbolo + magic). |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (long)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
         return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- Módulo de Sinais + trava de posição única (Requisitos 2 e 3)
//--- Só avalia o sinal se NÃO houver posição aberta deste EA.
   if(!HasOpenPosition() && CheckBuySignal())
     {
      Print("AlphaBot - Sinal de Compra validado (SMA + ADX + Price Action)!");

      //--- Execução de ordem a mercado (Requisito 3)
      if(trade.Buy(InpLoteInicial, _Symbol, 0, 0, 0, "AlphaBot Entry"))
        {
         Print("AlphaBot - Ordem de COMPRA executada com sucesso. Ticket: ",
               trade.ResultOrder(), " | Preço: ", trade.ResultPrice());
        }
      else
        {
         Print("AlphaBot - ERRO ao enviar ordem de COMPRA. Retcode: ",
               trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(),
               ") | Erro: ", GetLastError());
        }
     }

//--- Demais lógicas (Gradiente Linear Duplo, Offsetting e HEDGE)
//---     serão implementadas aqui.
  }
//+------------------------------------------------------------------+
