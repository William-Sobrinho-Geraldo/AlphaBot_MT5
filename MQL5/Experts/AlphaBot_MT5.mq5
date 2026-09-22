//+------------------------------------------------------------------+
//|                                              AlphaBot_MT5.mq5     |
//|                                                AlphaBot Trading  |
//|                                                                  |
//| Foco: Padrões de reversão (Martelo, Martelo Invertido e Engolfo). |
//| Filtro de tendência macro por Média Móvel (EMA/SMA).             |
//+------------------------------------------------------------------+
#property copyright "AlphaBot Trading"
#property link      "https://www.mql5.com"
#property version   "1.40"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Ação a tomar quando surge um sinal oposto à posição aberta       |
//+------------------------------------------------------------------+
enum ENUM_OPPOSITE_ACTION
  {
   ACTION_DO_NOTHING        = 0, // Ignora o sinal oposto
   ACTION_CLOSE_ONLY        = 1, // Fecha a posição atual
   ACTION_CLOSE_AND_REVERSE = 2  // Fecha e reverte a posição
  };

//+------------------------------------------------------------------+
//| Parâmetros Operacionais - Interface nativa do MT5                |
//+------------------------------------------------------------------+
input group "=== AlphaBot - Parâmetros Operacionais ==="
input double InpLoteInicial      = 0.01; // Lote inicial
input int    InpPassoGridPontos  = 200;  // Passo do grid (pontos)
input int    InpStopLossGlobal   = 300;  // Stop Loss global (pontos)
input int    InpTakeProfitGlobal = 300;  // Take Profit global (pontos)

input group "=== AlphaBot - Ativação de Padrões ==="
input bool InpUseHammer    = true; // Usar Martelo / Martelo Invertido
input bool InpUseEngulfing = true; // Usar Engolfo (Alta / Baixa)

input group "=== AlphaBot - Configurações do Martelo ==="
input double InpMinLongShadowRatio     = 2.0; // Sombra longa mín. (x Corpo)
input double InpMaxOppositeShadowRatio = 0.5; // Sombra oposta máx. (x Corpo)

input group "=== AlphaBot - Configurações do Engolfo ==="
input double InpMinEngulfingBodyRatio = 1.1; // Cobertura mínima (ex: 1.1 = +10%)
input int    InpMinCandleBodyPoints   = 50;  // Corpo mínimo (pontos)

input group "=== AlphaBot - Filtro de Tendência Macro ==="
input int    InpMaMacroPeriod        = 200;       // Período da média macro
input ENUM_MA_METHOD InpMaMacroMethod = MODE_EMA; // Método (EMA ou SMA)
input ENUM_APPLIED_PRICE InpMaMacroAppliedPrice = PRICE_CLOSE; // Preço aplicado

input group "=== AlphaBot - Execução de Ordens ==="
input long   InpMagicNumber    = 123456; // Magic Number
input ENUM_OPPOSITE_ACTION InpOppositeAction = ACTION_CLOSE_AND_REVERSE; // Ação em sinal oposto

//+------------------------------------------------------------------+
//| Enumeração dos sinais de price action                            |
//+------------------------------------------------------------------+
enum ENUM_ALPHA_SIGNAL
  {
   SIGNAL_NONE = 0, // Sem sinal
   SIGNAL_BUY  = 1, // Compra (Martelo / Engolfo de Alta)
   SIGNAL_SELL =-1  // Venda (Martelo Invertido / Engolfo de Baixa)
  };

//+------------------------------------------------------------------+
//| Objeto de execução e detalhes do último sinal (para logs)        |
//+------------------------------------------------------------------+
CTrade trade;

int    g_handle_ma_macro = INVALID_HANDLE; // Handle da Média Móvel Macro

string g_signalPadrao = ""; // Nome do padrão que gerou o último sinal

//+------------------------------------------------------------------+
//| Cria e valida o handle da Média Móvel Macro.                      |
//+------------------------------------------------------------------+
bool InitMediaMacro()
  {
   g_handle_ma_macro=iMA(_Symbol, PERIOD_CURRENT, InpMaMacroPeriod, 0,
                         InpMaMacroMethod, InpMaMacroAppliedPrice);
   if(g_handle_ma_macro==INVALID_HANDLE)
     {
      Print("AlphaBot - ERRO: falha ao criar handle da Média Macro ",
            InpMaMacroPeriod, " (erro ", GetLastError(), ").");
      return(false);
     }

   Print("AlphaBot - Média Macro inicializada (período=", InpMaMacroPeriod,
         " | método=", EnumToString(InpMaMacroMethod),
         " | preço=", EnumToString(InpMaMacroAppliedPrice), ").");
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

//--- Criação e validação do handle da Média Móvel Macro
   if(!InitMediaMacro())
     {
      Alert("AlphaBot - ERRO: falha ao inicializar a Média Macro. Robô NÃO carregado.");
      return(INIT_FAILED);
     }

//--- Configuração do objeto de execução
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);

   if(!trade.SetTypeFillingBySymbol(_Symbol))
      Print("AlphaBot - AVISO: não foi possível definir o modo de preenchimento (filling) para ",
            _Symbol, " (erro ", GetLastError(), ").");

   Print("AlphaBot - Padrões ativos -> Martelo: ", (InpUseHammer ? "ON" : "OFF"),
         " | Engolfo: ", (InpUseEngulfing ? "ON" : "OFF"), ".");
   Print("AlphaBot - Ação em sinal oposto: ", EnumToString(InpOppositeAction), ".");
   Print("AlphaBot - Inicializado com sucesso: conta em modo HEDGE. MagicNumber=",
         InpMagicNumber, ".");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_handle_ma_macro!=INVALID_HANDLE)
     {
      IndicatorRelease(g_handle_ma_macro);
      g_handle_ma_macro=INVALID_HANDLE;
     }

   Print("AlphaBot - Desinicializado. Código de motivo: ", reason);
  }

//+------------------------------------------------------------------+
//| Martelo: sombra inferior longa, corpo pequeno no topo da range.  |
//+------------------------------------------------------------------+
bool IsHammer(const MqlRates &candle)
  {
   double range        = candle.high - candle.low;
   double corpo        = MathAbs(candle.close - candle.open);
   double sombraInferior = MathMin(candle.open, candle.close) - candle.low;
   double sombraSuperior = candle.high - MathMax(candle.open, candle.close);

   if(range <= 0.0 || corpo <= 0.0)
      return(false);

//--- sombra inferior >= 2x o corpo
   if(sombraInferior < InpMinLongShadowRatio * corpo)
      return(false);

//--- sombra superior pequena ou ausente
   if(sombraSuperior > InpMaxOppositeShadowRatio * corpo)
      return(false);

//--- corpo localizado na parte superior da range
   double centroCorpo = (candle.open + candle.close) / 2.0;
   double centroRange = (candle.high + candle.low) / 2.0;
   if(centroCorpo < centroRange)
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Martelo Invertido: sombra superior longa, corpo pequeno na base. |
//+------------------------------------------------------------------+
bool IsInvertedHammer(const MqlRates &candle)
  {
   double range        = candle.high - candle.low;
   double corpo        = MathAbs(candle.close - candle.open);
   double sombraInferior = MathMin(candle.open, candle.close) - candle.low;
   double sombraSuperior = candle.high - MathMax(candle.open, candle.close);

   if(range <= 0.0 || corpo <= 0.0)
      return(false);

//--- sombra superior >= 2x o corpo
   if(sombraSuperior < InpMinLongShadowRatio * corpo)
      return(false);

//--- sombra inferior pequena ou ausente
   if(sombraInferior > InpMaxOppositeShadowRatio * corpo)
      return(false);

//--- corpo localizado na parte inferior da range
   double centroCorpo = (candle.open + candle.close) / 2.0;
   double centroRange = (candle.high + candle.low) / 2.0;
   if(centroCorpo > centroRange)
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Valida o corpo do candle de engolfo: tamanho mínimo e cobertura. |
//| candle1 = engolfador (candle [1]) | candle2 = engolfado (candle [2])|
//+------------------------------------------------------------------+
bool IsValidEngulfingBody(const MqlRates &candle1, const MqlRates &candle2)
  {
   double corpoCandle1 = MathAbs(candle1.close - candle1.open);
   double corpoCandle2 = MathAbs(candle2.close - candle2.open);

//--- corpo mínimo em pontos (evita ruído de mercado)
   if(corpoCandle1 < InpMinCandleBodyPoints * _Point)
      return(false);

//--- sem corpo no candle engolfado não há cobertura a validar
   if(corpoCandle2 <= 0.0)
      return(false);

//--- corpo engolfador deve cobrir o engolfado com a folga mínima configurada
   return(corpoCandle1 >= InpMinEngulfingBodyRatio * corpoCandle2);
  }

//+------------------------------------------------------------------+
//| Engolfo de Alta: candle[1] de ALTA engole o corpo do candle[2]   |
//| de BAIXA. Cores estritas: Close[1]>Open[1] e Open[2]>Close[2].   |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(const MqlRates &candle1, const MqlRates &candle2)
  {
//--- candle [1] (engolfador) TEM QUE SER DE ALTA
   if(!(candle1.close > candle1.open))
      return(false);

//--- candle [2] (engolfado) TEM QUE SER DE BAIXA
   if(!(candle2.open > candle2.close))
      return(false);

//--- regras de proporção e tamanho mínimo do corpo
   if(!IsValidEngulfingBody(candle1, candle2))
      return(false);

//--- candle [1] engole totalmente o corpo do candle [2]
   return(candle1.open <= candle2.close && candle1.close >= candle2.open);
  }

//+------------------------------------------------------------------+
//| Engolfo de Baixa: candle[1] de BAIXA engole o corpo do candle[2] |
//| de ALTA. Cores estritas: Open[1]>Close[1] e Close[2]>Open[2].    |
//+------------------------------------------------------------------+
bool IsBearishEngulfing(const MqlRates &candle1, const MqlRates &candle2)
  {
//--- candle [1] (engolfador) TEM QUE SER DE BAIXA
   if(!(candle1.open > candle1.close))
      return(false);

//--- candle [2] (engolfado) TEM QUE SER DE ALTA
   if(!(candle2.close > candle2.open))
      return(false);

//--- regras de proporção e tamanho mínimo do corpo
   if(!IsValidEngulfingBody(candle1, candle2))
      return(false);

//--- candle [1] engole totalmente o corpo do candle [2]
   return(candle1.open >= candle2.close && candle1.close <= candle2.open);
  }

//+------------------------------------------------------------------+
//| Avalia o price action do candle [1] + filtro de tendência macro. |
//| Compra (Martelo) exige Preço > Média Macro.                      |
//| Venda (Martelo Invertido) exige Preço < Média Macro.             |
//+------------------------------------------------------------------+
ENUM_ALPHA_SIGNAL CheckPriceActionSignal()
  {
   if(g_handle_ma_macro==INVALID_HANDLE)
     {
      Print("AlphaBot - ERRO: CheckPriceActionSignal sem handle da Média Macro.");
      return(SIGNAL_NONE);
     }

   if(Bars(_Symbol, PERIOD_CURRENT) < InpMaMacroPeriod + 3)
     {
      Print("AlphaBot - AVISO: barras insuficientes (",
            Bars(_Symbol, PERIOD_CURRENT), ") para a Média Macro ",
            InpMaMacroPeriod, ".");
      return(SIGNAL_NONE);
     }

//--- Candles [1] e [2]. ArraySetAsSeries garante rates[0]=candle[1], rates[1]=candle[2]
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 1, 2, rates) != 2)
     {
      Print("AlphaBot - ERRO: CopyRates retornou ", GetLastError(), ".");
      return(SIGNAL_NONE);
     }

//--- Valor da Média Macro no candle [1]
   double ma[];
   if(CopyBuffer(g_handle_ma_macro, 0, 1, 1, ma) != 1)
     {
      Print("AlphaBot - ERRO: CopyBuffer(Média Macro) retornou ", GetLastError(), ".");
      return(SIGNAL_NONE);
     }

   double fechamento = rates[0].close;
   double valorMa    = ma[0];

//--- Gatilho de COMPRA: (Martelo OU Engolfo de Alta, se habilitados) + preço acima da Média Macro
   bool marteloCompra = InpUseHammer    && IsHammer(rates[0]);
   bool engolfoCompra = InpUseEngulfing && IsBullishEngulfing(rates[0], rates[1]);

   if(marteloCompra || engolfoCompra)
     {
      g_signalPadrao = (marteloCompra ? "Martelo" : "Engolfo de Alta");

      if(fechamento > valorMa)
        {
         Print("SINAL DE COMPRA VALIDADO: ", g_signalPadrao, " detectado E Preço (",
               DoubleToString(fechamento, _Digits), ") > Média Macro (",
               DoubleToString(valorMa, _Digits), ")");
         return(SIGNAL_BUY);
        }

      Print("SINAL DE COMPRA REJEITADO: ", g_signalPadrao, " detectado, mas Preço está ",
            "abaixo da Média Macro (Contra-tendência). Preço=",
            DoubleToString(fechamento, _Digits), " | Média Macro=",
            DoubleToString(valorMa, _Digits));
      return(SIGNAL_NONE);
     }

//--- Gatilho de VENDA: (Martelo Invertido OU Engolfo de Baixa, se habilitados) + preço abaixo da Média Macro
   bool marteloInvertido = InpUseHammer    && IsInvertedHammer(rates[0]);
   bool engolfoBaixa     = InpUseEngulfing && IsBearishEngulfing(rates[0], rates[1]);

   if(marteloInvertido || engolfoBaixa)
     {
      g_signalPadrao = (marteloInvertido ? "Martelo Invertido" : "Engolfo de Baixa");

      if(fechamento < valorMa)
        {
         Print("SINAL DE VENDA VALIDADO: ", g_signalPadrao, " detectado E Preço (",
               DoubleToString(fechamento, _Digits), ") < Média Macro (",
               DoubleToString(valorMa, _Digits), ")");
         return(SIGNAL_SELL);
        }

      Print("SINAL DE VENDA REJEITADO: ", g_signalPadrao, " detectado, mas Preço está ",
            "acima da Média Macro (Contra-tendência). Preço=",
            DoubleToString(fechamento, _Digits), " | Média Macro=",
            DoubleToString(valorMa, _Digits));
      return(SIGNAL_NONE);
     }

   return(SIGNAL_NONE);
  }

//+------------------------------------------------------------------+
//| Direção da posição aberta deste EA.                              |
//| Retorna 1=comprado, -1=vendido, 0=sem posição.                   |
//+------------------------------------------------------------------+
int GetOpenPositionDirection()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (long)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
        {
         ENUM_POSITION_TYPE tipo=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         return(tipo==POSITION_TYPE_BUY ? 1 : -1);
        }
     }

   return(0);
  }

//+------------------------------------------------------------------+
//| Encerra a posição aberta deste EA (símbolo + magic).             |
//+------------------------------------------------------------------+
bool CloseOpenPosition(ulong &closedTicket)
  {
   closedTicket=0;

   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (long)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
        {
         if(trade.PositionClose(ticket))
           {
            closedTicket=ticket;
            return(true);
           }

         Print("AlphaBot - ERRO ao encerrar posição ", ticket, ". Retcode: ",
               trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(),
               ") | Erro: ", GetLastError());
         return(false);
        }
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Executa ordem de COMPRA (Martelo) com SL/TP globais.             |
//+------------------------------------------------------------------+
void ExecuteBuy()
  {
   double precoEntrada = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(precoEntrada - (InpStopLossGlobal * _Point), _Digits);
   double tp = NormalizeDouble(precoEntrada + (InpTakeProfitGlobal * _Point), _Digits);

   if(trade.Buy(InpLoteInicial, _Symbol, precoEntrada, sl, tp, "AlphaBot Compra"))
     {
      Print("=== ALPHABOT: ORDEM DE COMPRA EXECUTADA ===");
      Print("SINAL DE COMPRA: ", g_signalPadrao, " detectado no candle [1]");
      Print("Preço de Entrada: ", DoubleToString(trade.ResultPrice(), _Digits),
            " | SL: ", DoubleToString(sl, _Digits),
            " | TP: ", DoubleToString(tp, _Digits));
      Print("AlphaBot - Ticket: ", trade.ResultOrder(), ".");
     }
   else
     {
      Print("AlphaBot - ERRO ao enviar ordem de COMPRA. Retcode: ",
            trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(),
            ") | Erro: ", GetLastError());
     }
  }

//+------------------------------------------------------------------+
//| Executa ordem de VENDA (Martelo Invertido / Engolfo de Baixa).   |
//+------------------------------------------------------------------+
void ExecuteSell()
  {
   double precoEntrada = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(precoEntrada + (InpStopLossGlobal * _Point), _Digits);
   double tp = NormalizeDouble(precoEntrada - (InpTakeProfitGlobal * _Point), _Digits);

   if(trade.Sell(InpLoteInicial, _Symbol, precoEntrada, sl, tp, "AlphaBot Venda"))
     {
      Print("=== ALPHABOT: ORDEM DE VENDA EXECUTADA ===");
      Print("SINAL DE VENDA: ", g_signalPadrao, " detectado no candle [1]");
      Print("Preço de Entrada: ", DoubleToString(trade.ResultPrice(), _Digits),
            " | SL: ", DoubleToString(sl, _Digits),
            " | TP: ", DoubleToString(tp, _Digits));
      Print("AlphaBot - Ticket: ", trade.ResultOrder(), ".");
     }
   else
     {
      Print("AlphaBot - ERRO ao enviar ordem de VENDA. Retcode: ",
            trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(),
            ") | Erro: ", GetLastError());
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- Avalia o price action do candle [1] + filtro de tendência macro
   ENUM_ALPHA_SIGNAL sinal=CheckPriceActionSignal();

   if(sinal==SIGNAL_NONE)
      return;

   int direcaoAtual=GetOpenPositionDirection();

//--- Sem posição aberta: abre na direção do sinal
   if(direcaoAtual==0)
     {
      if(sinal==SIGNAL_BUY)
         ExecuteBuy();
      else
         ExecuteSell();

      return;
     }

//--- Com posição aberta: verifica se o sinal é oposto à posição
   bool sinalOposto=((direcaoAtual==1 && sinal==SIGNAL_SELL) ||
                     (direcaoAtual==-1 && sinal==SIGNAL_BUY));

   if(!sinalOposto)
     {
      Print("AlphaBot - Sinal de ", (sinal==SIGNAL_BUY ? "COMPRA" : "VENDA"),
            " (", g_signalPadrao, ") já na direção da posição atual. Ignorado.");
      return;
     }

//--- Sinal oposto à posição: aplica a ação configurada
   Print("AlphaBot - Sinal oposto de ", (sinal==SIGNAL_BUY ? "COMPRA" : "VENDA"),
         " (", g_signalPadrao, ") com posição aberta. Ação: ",
         EnumToString(InpOppositeAction), ".");

   if(InpOppositeAction==ACTION_DO_NOTHING)
     {
      Print("AlphaBot - ACTION_DO_NOTHING: operação atual mantida; sinal oposto ignorado.");
      return;
     }

   ulong ticketFechado=0;
   if(!CloseOpenPosition(ticketFechado))
      return;

   Print("AlphaBot - Posição ", ticketFechado, " encerrada por sinal oposto (",
         g_signalPadrao, ").");

   if(InpOppositeAction==ACTION_CLOSE_ONLY)
     {
      Print("AlphaBot - ACTION_CLOSE_ONLY: posição encerrada. Aguardando novo sinal.");
      return;
     }

//--- ACTION_CLOSE_AND_REVERSE: abre imediatamente na direção oposta
   Print("AlphaBot - ACTION_CLOSE_AND_REVERSE: revertendo para ",
         (sinal==SIGNAL_BUY ? "COMPRA" : "VENDA"), ".");
   if(sinal==SIGNAL_BUY)
      ExecuteBuy();
   else
      ExecuteSell();

//--- Demais lógicas (Gradiente Linear Duplo, Offsetting e HEDGE)
//---     serão implementadas aqui.
  }
//+------------------------------------------------------------------+
