//+------------------------------------------------------------------+
//|                                              AlphaBot_MT5.mq5     |
//|                                                AlphaBot Trading  |
//|                                                                  |
//| Foco: Padrões de reversão (Martelo, Martelo Invertido e Engolfo). |
//| Filtro de tendência macro por Média Móvel (EMA/SMA).             |
//+------------------------------------------------------------------+
#property copyright "AlphaBot Trading"
#property link      "https://www.mql5.com"
#property version   "1.50"

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

input group "=== AlphaBot - Gradiente Linear (Grid Dinâmico) ==="
input bool   InpEnableGL  = true;   // Ativar Gradiente Linear?
input int    InpLevelsSL  = 4;      // Número de Níveis entre Entrada e Stop Loss
input int    InpLevelsTP  = 4;      // Número de Níveis entre Entrada e Take Profit
input long   InpMagicGL   = 654321; // Magic Number exclusivo das posições do Gradiente

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
//| Estado global do Gradiente Linear (Grade Virtual)                |
//+------------------------------------------------------------------+
bool   g_glAtivo       = false; // Gradiente Linear em operação?
int    g_glDirecao     = 0;     // 1=comprado, -1=vendido
double g_glEntrada     = 0.0;   // Preço de entrada da operação principal (nível 0)
double g_glGlobalSL    = 0.0;   // Preço do Stop Loss global
double g_glGlobalTP    = 0.0;   // Preço do Take Profit global
double g_glStepSL      = 0.0;   // Tamanho (em preço) de cada nível rumo ao SL
double g_glStepTP      = 0.0;   // Tamanho (em preço) de cada nível rumo ao TP
double g_glUltimaMetrica = 0.0; // Última "métrica favorável" observada (evita reaberturas)

bool   g_glNivelAberto[];  // Estado por nível: há posição aberta?
ulong  g_glNivelTicket[];  // Ticket associado a cada nível da grade

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

//--- Trava de Segurança do Gradiente Linear: exige conta HEDGE
   if(InpEnableGL)
     {
      long modoMargem=AccountInfoInteger(ACCOUNT_MARGIN_MODE);

      if(modoMargem!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
        {
         Alert("AlphaBot - ERRO: O Gradiente Linear exige uma conta no modo HEDGE ",
               "(ACCOUNT_MARGIN_MODE_RETAIL_HEDGING). Modo detectado: ",
               EnumToString((ENUM_ACCOUNT_MARGIN_MODE)modoMargem),
               ". Desative o Gradiente Linear (InpEnableGL=false) ou utilize uma conta Hedge. ",
               "Robô NÃO carregado.");
         Print("AlphaBot - OnInit abortado: Gradiente Linear exige conta Hedge (modo atual: ",
               EnumToString((ENUM_ACCOUNT_MARGIN_MODE)modoMargem), ").");
         return(INIT_FAILED);
        }
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
   Print("AlphaBot - Gradiente Linear: ", (InpEnableGL ? "ATIVO" : "INATIVO"),
         " (níveis SL=", InpLevelsSL, " | níveis TP=", InpLevelsTP,
         " | lote=", DoubleToString(InpLoteInicial, 2),
         " | MagicGL=", InpMagicGL, ").");
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

//+==================================================================+
//|                    MÓDULO GRADIENTE LINEAR                        |
//|  Grade virtual de níveis monitorada via OnTick. As sub-operações  |
//|  são executadas a mercado quando o preço "toca" cada nível.       |
//+==================================================================+

//+------------------------------------------------------------------+
//| Converte um deslocamento de nível (offset) no índice do array.    |
//| offset 0 = entrada | negativos = rumo ao SL | positivos = rumo TP |
//+------------------------------------------------------------------+
int GL_IndiceDoNivel(const int offset)
  {
   return(offset + InpLevelsSL);
  }

//+------------------------------------------------------------------+
//| Distância assinada (em preço) do nível em relação à entrada.      |
//| Positivo = favorável à operação (rumo ao TP).                     |
//+------------------------------------------------------------------+
double GL_MetricaDoNivel(const int offset)
  {
   if(offset >= 0)
      return(offset * g_glStepTP);

   return(offset * g_glStepSL);
  }

//+------------------------------------------------------------------+
//| Preço exato de um nível da grade virtual.                         |
//+------------------------------------------------------------------+
double GL_PrecoDoNivel(const int offset)
  {
   double metrica = GL_MetricaDoNivel(offset);

   if(g_glDirecao == 1)
      return(g_glEntrada + metrica);

   return(g_glEntrada - metrica);
  }

//+------------------------------------------------------------------+
//| Converte um preço qualquer na "métrica favorável" corrente.       |
//+------------------------------------------------------------------+
double GL_MetricaDoPreco(const double preco)
  {
   if(g_glDirecao == 1)
      return(preco - g_glEntrada);

   return(g_glEntrada - preco);
  }

//+------------------------------------------------------------------+
//| Cruzamento favorável: a métrica passou de baixo para o nível.     |
//+------------------------------------------------------------------+
bool GL_CruzouFavoravel(const double prevM, const double curM, const int offset)
  {
   double nivel = GL_MetricaDoNivel(offset);
   return(prevM < nivel && curM >= nivel);
  }

//+------------------------------------------------------------------+
//| Cruzamento adverso: a métrica caiu de cima para baixo do nível.   |
//+------------------------------------------------------------------+
bool GL_CruzouAdverso(const double prevM, const double curM, const int offset)
  {
   double nivel = GL_MetricaDoNivel(offset);
   return(prevM >= nivel && curM < nivel);
  }

//+------------------------------------------------------------------+
//| Normaliza o lote conforme as restrições do símbolo.               |
//+------------------------------------------------------------------+
double GL_NormalizarLote(double lote)
  {
   double minLote  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLote  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double passo    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(passo <= 0.0)
      passo = 0.01;

   lote = MathRound(lote / passo) * passo;

   if(lote < minLote)
      lote = minLote;
   if(lote > maxLote)
      lote = maxLote;

   return(NormalizeDouble(lote, 2));
  }

//+------------------------------------------------------------------+
//| Localiza o ticket da posição principal (âncora) deste EA.         |
//+------------------------------------------------------------------+
ulong GL_TicketAncora()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (long)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return(ticket);
     }

   return(0);
  }

//+------------------------------------------------------------------+
//| Localiza o ticket da sub-operação recém-aberta na grade.          |
//+------------------------------------------------------------------+
ulong GL_TicketRecemAberto()
  {
   ulong melhor = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (long)PositionGetInteger(POSITION_MAGIC) != InpMagicGL)
         continue;

      bool mapeado = false;
      for(int j = 0; j < ArraySize(g_glNivelTicket); j++)
         if(g_glNivelTicket[j] == ticket)
           {
            mapeado = true;
            break;
           }

      if(!mapeado && ticket > melhor)
         melhor = ticket;
     }

   return(melhor);
  }

//+------------------------------------------------------------------+
//| Verifica se ainda existe alguma posição ativa deste robô.         |
//+------------------------------------------------------------------+
bool GL_ExistePosicaoAtiva()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long magic = (long)PositionGetInteger(POSITION_MAGIC);
      if(magic == InpMagicNumber || magic == InpMagicGL)
         return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Reinicia completamente o estado da grade virtual.                 |
//+------------------------------------------------------------------+
void ResetGL(const string motivo = "")
  {
   if(g_glAtivo && motivo != "")
      Print("AlphaBot GL - Grade encerrada. Motivo: ", motivo);

   g_glAtivo        = false;
   g_glDirecao      = 0;
   g_glEntrada      = 0.0;
   g_glGlobalSL     = 0.0;
   g_glGlobalTP     = 0.0;
   g_glStepSL       = 0.0;
   g_glStepTP       = 0.0;
   g_glUltimaMetrica= 0.0;

   ArrayResize(g_glNivelAberto, 0);
   ArrayResize(g_glNivelTicket, 0);
  }

//+------------------------------------------------------------------+
//| Calcula os níveis da grade a partir do preço de entrada.          |
//| Deve ser chamada imediatamente após abrir a operação principal.   |
//+------------------------------------------------------------------+
void CalculateGLLevels(const double precoEntrada, const int direcao)
  {
   if(!InpEnableGL)
      return;

   ResetGL();

   g_glAtivo    = true;
   g_glDirecao  = direcao;
   g_glEntrada  = precoEntrada;

//--- Distâncias globais e passo de cada nível
   double distanciaSL = InpStopLossGlobal * _Point;
   double distanciaTP = InpTakeProfitGlobal * _Point;

   g_glStepSL = distanciaSL / MathMax(1, InpLevelsSL);
   g_glStepTP = distanciaTP / MathMax(1, InpLevelsTP);

//--- Preços dos extremos (SL e TP globais)
   if(direcao == 1)
     {
      g_glGlobalSL = precoEntrada - distanciaSL;
      g_glGlobalTP = precoEntrada + distanciaTP;
     }
   else
     {
      g_glGlobalSL = precoEntrada + distanciaSL;
      g_glGlobalTP = precoEntrada - distanciaTP;
     }

//--- A métrica inicial é zero (preço posicionado na entrada/nível 0)
   g_glUltimaMetrica = 0.0;

//--- Alocação dos arrays da grade virtual
   int totalNiveis = InpLevelsSL + InpLevelsTP + 1;
   ArrayResize(g_glNivelAberto, totalNiveis);
   ArrayResize(g_glNivelTicket, totalNiveis);

   for(int i = 0; i < totalNiveis; i++)
     {
      g_glNivelAberto[i] = false;
      g_glNivelTicket[i] = 0;
     }

//--- Registra a operação principal como âncora do nível 0
   ulong ticketAncora = GL_TicketAncora();
   int   idx0         = GL_IndiceDoNivel(0);

   g_glNivelAberto[idx0] = (ticketAncora != 0);
   g_glNivelTicket[idx0] = ticketAncora;

   Print("=== GRADIENTE LINEAR ATIVADO ===");
   Print("AlphaBot GL - Direção: ", (direcao == 1 ? "COMPRA" : "VENDA"),
         " | Entrada: ", DoubleToString(precoEntrada, _Digits),
         " | Níveis SL: ", InpLevelsSL, " (passo ",
         DoubleToString(g_glStepSL, _Digits), ")",
         " | Níveis TP: ", InpLevelsTP, " (passo ",
         DoubleToString(g_glStepTP, _Digits), ")");
   Print("AlphaBot GL - Global SL: ", DoubleToString(g_glGlobalSL, _Digits),
         " | Global TP: ", DoubleToString(g_glGlobalTP, _Digits),
         " | Lote: ", DoubleToString(InpLoteInicial, 2),
         " | MagicGL: ", InpMagicGL,
         " | Âncora: ", ticketAncora, ".");
  }

//+------------------------------------------------------------------+
//| Sincroniza o estado: níveis cujos tickets foram fechados pelo     |
//| broker (TP/SL individuais) são liberados para eventual recompra.  |
//+------------------------------------------------------------------+
void GL_SincronizarEstado()
  {
   int total = ArraySize(g_glNivelAberto);

   for(int i = 0; i < total; i++)
     {
      if(!g_glNivelAberto[i])
         continue;

      ulong ticket = g_glNivelTicket[i];

      if(ticket == 0 || !PositionSelectByTicket(ticket))
        {
         g_glNivelAberto[i] = false;
         g_glNivelTicket[i] = 0;
        }
     }
  }

//+------------------------------------------------------------------+
//| Abre uma sub-operação a mercado no nível informado.               |
//| O Take Profit é posicionado no nível imediatamente acima (k+1).   |
//| O Stop Loss é o Stop Loss global (proteção individual).           |
//+------------------------------------------------------------------+
bool GL_OpenPosition(const int offset)
  {
   if(!g_glAtivo)
      return(false);

   int idx = GL_IndiceDoNivel(offset);
   if(idx < 0 || idx >= ArraySize(g_glNivelAberto))
      return(false);

   if(g_glNivelAberto[idx])
      return(false);

//--- Não abre no extremo do TP global (esse nível é de encerramento total)
   int offsetAlvo = offset + 1;
   if(offsetAlvo > InpLevelsTP)
      return(false);

   double tp  = NormalizeDouble(GL_PrecoDoNivel(offsetAlvo), _Digits);
   double sl  = NormalizeDouble(g_glGlobalSL, _Digits);
   double lote= GL_NormalizarLote(InpLoteInicial);

   if(lote <= 0.0)
     {
      Print("AlphaBot GL - ERRO: lote inválido para o símbolo ", _Symbol, ".");
      return(false);
     }

   string comentario = "GL Nivel " + IntegerToString(offset);

   trade.SetExpertMagicNumber(InpMagicGL);

   bool ok = false;
   if(g_glDirecao == 1)
      ok = trade.Buy(lote, _Symbol, 0.0, sl, tp, comentario);
   else
      ok = trade.Sell(lote, _Symbol, 0.0, sl, tp, comentario);

   ulong ticket = 0;

   if(ok)
     {
      ticket = GL_TicketRecemAberto();
      if(ticket == 0)
         ticket = (ulong)trade.ResultOrder();

      g_glNivelAberto[idx] = true;
      g_glNivelTicket[idx] = ticket;

      Print("AlphaBot GL - Sub-operação aberta no nível ", offset,
            " | ticket=", ticket,
            " | preço=", DoubleToString(trade.ResultPrice(), _Digits),
            " | TP=", DoubleToString(tp, _Digits),
            " | SL=", DoubleToString(sl, _Digits),
            " | lote=", DoubleToString(lote, 2), ".");
     }
   else
     {
      Print("AlphaBot GL - ERRO ao abrir sub-operação no nível ", offset,
            ". Retcode=", trade.ResultRetcode(),
            " (", trade.ResultRetcodeDescription(), ").");
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   return(ok);
  }

//+------------------------------------------------------------------+
//| Encerra a sub-operação associada a um nível (realização de lucro).|
//+------------------------------------------------------------------+
void GL_ClosePositionAt(const int offset, const string motivo)
  {
   int idx = GL_IndiceDoNivel(offset);
   if(idx < 0 || idx >= ArraySize(g_glNivelAberto))
      return;

   if(!g_glNivelAberto[idx])
      return;

   ulong ticket = g_glNivelTicket[idx];

   if(ticket == 0 || !PositionSelectByTicket(ticket))
     {
      g_glNivelAberto[idx] = false;
      g_glNivelTicket[idx] = 0;
      return;
     }

   if(trade.PositionClose(ticket))
      Print("AlphaBot GL - Nível ", offset, " encerrado no lucro (",
            motivo, ") | ticket=", ticket, ".");
   else
      Print("AlphaBot GL - ERRO ao encerrar nível ", offset, " | ticket=", ticket,
            ". Retcode=", trade.ResultRetcode(),
            " (", trade.ResultRetcodeDescription(), ").");

   g_glNivelAberto[idx] = false;
   g_glNivelTicket[idx] = 0;
  }

//+------------------------------------------------------------------+
//| ZONA DE DRAWDOWN / RECUO                                          |
//| A cada nível cruzado no sentido adverso, abre uma sub-operação    |
//| cujo TP aponta para o nível imediatamente superior.               |
//+------------------------------------------------------------------+
void CheckGLDrawdownZone(const double prevM, const double curM)
  {
//--- Do nível mais profundo (sem tocar o SL global) até o penúltimo
//--- nível rumo ao TP. Inclui o nível 0 (recuo do lucro para a entrada).
   for(int offset = -(InpLevelsSL - 1); offset <= InpLevelsTP - 1; offset++)
     {
      if(!GL_CruzouAdverso(prevM, curM, offset))
         continue;

      Print("AlphaBot GL - Preço cruzou o nível ", offset,
            " (zona de drawdown/recuo). Engatilhando sub-operação.");
      GL_OpenPosition(offset);
     }
  }

//+------------------------------------------------------------------+
//| ZONA DE LUCRO (rolagem de posições)                               |
//| Ao atingir o nível k: fecha a posição de k-1 e abre/engatilha     |
//| nova posição em k, com TP no nível k+1 (regra de ouro da zona TP).|
//+------------------------------------------------------------------+
void CheckGLProfitZone(const double prevM, const double curM)
  {
//--- Determina o nível mais alto alcançado neste movimento (trata gaps)
   int nivelMax = -1;
   for(int offset = 1; offset <= InpLevelsTP; offset++)
      if(GL_CruzouFavoravel(prevM, curM, offset))
         nivelMax = offset;

   if(nivelMax <= 0)
      return;

//--- O extremo superior é tratado pelo encerramento global
   if(nivelMax == InpLevelsTP)
      return;

//--- Realiza o lucro de todas as posições ancoradas abaixo do nível
//--- alcançado (na rolagem normal equivale a fechar o nível nivelMax-1)
   for(int offset = nivelMax - 1; offset >= -InpLevelsSL; offset--)
     {
      int idx = GL_IndiceDoNivel(offset);
      if(idx >= 0 && idx < ArraySize(g_glNivelAberto) && g_glNivelAberto[idx])
         GL_ClosePositionAt(offset,
                            "rolagem para o nível " + IntegerToString(nivelMax));
     }

//--- Regra de ouro: engatilha nova posição no nível alcançado rumo ao próximo
   GL_OpenPosition(nivelMax);
  }

//+------------------------------------------------------------------+
//| ENCERRAMENTO GLOBAL                                               |
//| Ao tocar exatamente o SL ou TP global, fecha TODAS as posições    |
//| do símbolo (principal + gradiente) e limpa a grade virtual.       |
//+------------------------------------------------------------------+
bool CheckGLGlobalClose(const double curM)
  {
   double metricaTP = g_glStepTP * InpLevelsTP;
   double metricaSL = -g_glStepSL * InpLevelsSL;

   if(curM >= metricaTP)
     {
      Print("AlphaBot GL - TAKE PROFIT GLOBAL atingido (",
            DoubleToString(g_glGlobalTP, _Digits), "). Encerramento total.");
      CloseAllGLPositions("TP Global");
      return(true);
     }

   if(curM <= metricaSL)
     {
      Print("AlphaBot GL - STOP LOSS GLOBAL atingido (",
            DoubleToString(g_glGlobalSL, _Digits), "). Encerramento total.");
      CloseAllGLPositions("SL Global");
      return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Fecha TODAS as posições deste robô (principal + gradiente) e     |
//| coloca a grade em modo de espera pelo próximo sinal técnico.      |
//+------------------------------------------------------------------+
void CloseAllGLPositions(const string motivo = "")
  {
   int fechadas = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long magic = (long)PositionGetInteger(POSITION_MAGIC);
      if(magic != InpMagicNumber && magic != InpMagicGL)
         continue;

      if(trade.PositionClose(ticket))
        {
         fechadas++;
        }
      else
        {
         Print("AlphaBot GL - ERRO no encerramento global | ticket=", ticket,
               ". Retcode=", trade.ResultRetcode(),
               " (", trade.ResultRetcodeDescription(), ").");
        }
     }

   Print("AlphaBot GL - Encerramento global executado (", motivo,
         "). Posições fechadas: ", fechadas, ".");

   ResetGL(motivo);
  }

//+------------------------------------------------------------------+
//| Orquestrador do Gradiente Linear, chamado a cada tick.            |
//+------------------------------------------------------------------+
void ManageGradient()
  {
   if(!g_glAtivo)
      return;

   double preco = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(preco <= 0.0)
      return;

   double curM  = GL_MetricaDoPreco(preco);
   double prevM = g_glUltimaMetrica;

//--- Libera níveis fechados pelo broker (TP/SL individuais)
   GL_SincronizarEstado();

//--- Encerramento global prioritário
   if(CheckGLGlobalClose(curM))
      return;

//--- Proteção: se nenhuma posição permanece ativa, encerra a grade
   if(!GL_ExistePosicaoAtiva())
     {
      Print("AlphaBot GL - Nenhuma posição ativa detectada. Grade encerrada; ",
            "aguardando novo sinal técnico.");
      ResetGL("Sem posições ativas.");
      return;
     }

//--- Avaliação dos cruzamentos de níveis nas duas zonas
   CheckGLDrawdownZone(prevM, curM);
   CheckGLProfitZone(prevM, curM);

   g_glUltimaMetrica = curM;
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

      if(InpEnableGL)
         CalculateGLLevels(trade.ResultPrice(), 1);
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

      if(InpEnableGL)
         CalculateGLLevels(trade.ResultPrice(), -1);
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
//--- Gradiente Linear ativo: gerencia a grade virtual de forma independente
   if(g_glAtivo)
     {
      ManageGradient();
      return;
     }

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
