//+------------------------------------------------------------------+
//|                                              AlphaBot_MT5.mq5     |
//|                                                AlphaBot Trading  |
//|                                                                  |
//| Foco: Padrões de reversão (Martelo, Martelo Invertido e Engolfo). |
//| Filtro de tendência macro por Média Móvel (EMA/SMA).             |
//| Variante: Grid Bidirecional com Hedge (Compra + Venda no mesmo   |
//| preço base, cada perna com Gradiente Linear independente).       |
//+------------------------------------------------------------------+
#property copyright "AlphaBot Trading"
#property link      "https://www.mql5.com"
#property version   "1.60"

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
input double InpLoteInicial      = 0.01; // Lote inicial (fixo em todas as reentradas)
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

input group "=== AlphaBot - Grid Bidirecional (Hedge) ==="
input bool   InpBidirectionalGrid  = false; // Ativar Grid Bidirecional (Compra + Venda simultâneas)
input long   InpMagicGLBuy         = 654321; // Magic Number das reentradas de COMPRA
input long   InpMagicGLSell        = 654322; // Magic Number das reentradas de VENDA
input double InpMaxDrawdownMoney   = 50.0;   // Perda Máxima Global (em $)
input double InpTargetProfitMoney  = 20.0;   // Lucro Alvo Global (em $)

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

bool   g_hedgeAtivo = false; // Sessão de Hedge Bidirecional iniciada? (mantém as 2 grelhas vivas)

//+------------------------------------------------------------------+
//| Estado de uma "perna" do Gradiente Linear (Grade Virtual).        |
//| Cada perna possui seu próprio Magic das reentradas e seus arrays  |
//| de níveis, garantindo que as reentradas de compra não se misturem |
//| com as reentradas de venda.                                       |
//+------------------------------------------------------------------+
class CGLGrid
  {
public:
   bool   ativo;          // Gradiente Linear desta perna em operação?
   int    direcao;        // 1=compra, -1=venda
   long   magicAncora;    // Magic da posição principal (âncora)
   long   magicSub;       // Magic exclusivo das reentradas (sub-operações)
   double entrada;        // Preço de entrada da operação principal (nível 0)
   double globalSL;       // Preço do Stop Loss global da perna
   double globalTP;       // Preço do Take Profit global da perna
   double stepSL;         // Tamanho (em preço) de cada nível rumo ao SL
   double stepTP;         // Tamanho (em preço) de cada nível rumo ao TP
   double ultimaMetrica;  // Última "métrica favorável" observada
   bool   nivelAberto[];  // Estado por nível: há posição aberta?
   ulong  nivelTicket[];  // Ticket associado a cada nível da grade
   datetime ultimoReseed; // Controle anti-spam das tentativas de re-seed
   datetime ultimoLog;    // Controle de throttling dos logs de depuração

   void DefinirMagics(const long anc, const long sub)
     {
      magicAncora = anc;
      magicSub    = sub;
     }
  };

CGLGrid g_glGrid;  // Modo unidirecional (InpEnableGL)
CGLGrid g_glBuy;   // Perna de COMPRA do Grid Bidirecional
CGLGrid g_glSell;  // Perna de VENDA do Grid Bidirecional

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

//--- O Grid Bidirecional depende do Gradiente Linear para gerenciar as pernas
   if(InpBidirectionalGrid && !InpEnableGL)
     {
      Alert("AlphaBot - ERRO: o Grid Bidirecional exige o Gradiente Linear ativo ",
            "(InpEnableGL=true) para gerenciar as pernas de Compra e Venda. Robô NÃO carregado.");
      Print("AlphaBot - OnInit abortado: InpBidirectionalGrid=true com InpEnableGL=false.");
      return(INIT_FAILED);
     }

//--- As pernas de compra e venda NÃO podem compartilhar o mesmo Magic de reentrada
   if(InpBidirectionalGrid && InpMagicGLBuy==InpMagicGLSell)
     {
      Alert("AlphaBot - ERRO: InpMagicGLBuy e InpMagicGLSell devem ser diferentes ",
            "para não misturar as reentradas da compra com as da venda. Robô NÃO carregado.");
      Print("AlphaBot - OnInit abortado: Magics das pernas idênticos (", InpMagicGLBuy, ").");
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

//--- Associação dos Magics a cada perna do Gradiente Linear.
//--- No Grid Bidirecional cada perna usa um Magic PRÓPRIO (âncora + reentradas),
//--- garantindo isolamento total: as reentradas de compra nunca se confundem
//--- com as de venda em nenhuma varredura de posições.
   g_glGrid.DefinirMagics(InpMagicNumber, InpMagicGL);
   g_glBuy.DefinirMagics(InpMagicGLBuy, InpMagicGLBuy);
   g_glSell.DefinirMagics(InpMagicGLSell, InpMagicGLSell);

   ResetGL(g_glGrid);
   ResetGL(g_glBuy);
   ResetGL(g_glSell);

   Print("AlphaBot - Padrões ativos -> Martelo: ", (InpUseHammer ? "ON" : "OFF"),
         " | Engolfo: ", (InpUseEngulfing ? "ON" : "OFF"), ".");
   Print("AlphaBot - Ação em sinal oposto: ", EnumToString(InpOppositeAction), ".");
   Print("AlphaBot - Gradiente Linear: ", (InpEnableGL ? "ATIVO" : "INATIVO"),
         " (níveis SL=", InpLevelsSL, " | níveis TP=", InpLevelsTP,
         " | lote=", DoubleToString(InpLoteInicial, 2),
         " | MagicGL=", InpMagicGL, ").");
   Print("AlphaBot - Grid Bidirecional: ", (InpBidirectionalGrid ? "ATIVO" : "INATIVO"),
         " (Magic BUY=", InpMagicGLBuy, " | Magic SELL=", InpMagicGLSell,
         " | Alvo=$", DoubleToString(InpTargetProfitMoney, 2),
         " | Perda máx=$", DoubleToString(InpMaxDrawdownMoney, 2), ").");
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
//|  Todas as funções operam sobre uma "perna" (CGLGrid), permitindo  |
//|  gerenciar COMPRA e VENDA simultaneamente e de forma espelhada.   |
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
double GL_MetricaDoNivel(CGLGrid &st, const int offset)
  {
   if(offset >= 0)
      return(offset * st.stepTP);

   return(offset * st.stepSL);
  }

//+------------------------------------------------------------------+
//| Preço exato de um nível da grade virtual.                         |
//| Compra: metrica positiva sobe | Venda: metrica positiva desce.    |
//+------------------------------------------------------------------+
double GL_PrecoDoNivel(CGLGrid &st, const int offset)
  {
   double metrica = GL_MetricaDoNivel(st, offset);

   if(st.direcao == 1)
      return(st.entrada + metrica);

   return(st.entrada - metrica);
  }

//+------------------------------------------------------------------+
//| Converte um preço qualquer na "métrica favorável" corrente.       |
//+------------------------------------------------------------------+
double GL_MetricaDoPreco(CGLGrid &st, const double preco)
  {
   if(st.direcao == 1)
      return(preco - st.entrada);

   return(st.entrada - preco);
  }

//+------------------------------------------------------------------+
//| Cruzamento favorável: a métrica passou de baixo para o nível.     |
//+------------------------------------------------------------------+
bool GL_CruzouFavoravel(CGLGrid &st, const double prevM, const double curM, const int offset)
  {
   double nivel = GL_MetricaDoNivel(st, offset);
   return(prevM < nivel && curM >= nivel);
  }

//+------------------------------------------------------------------+
//| Cruzamento adverso: a métrica caiu de cima para baixo do nível.   |
//+------------------------------------------------------------------+
bool GL_CruzouAdverso(CGLGrid &st, const double prevM, const double curM, const int offset)
  {
   double nivel = GL_MetricaDoNivel(st, offset);
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
//| Verifica se um Magic pertence a este robô (qualquer perna).       |
//+------------------------------------------------------------------+
bool GL_MagicPertenceAoRobo(const long magic)
  {
   return(magic == InpMagicNumber ||
          magic == InpMagicGL     ||
          magic == InpMagicGLBuy  ||
          magic == InpMagicGLSell);
  }

//+------------------------------------------------------------------+
//| Localiza o ticket da posição principal (âncora) desta perna.      |
//| Filtra por Magic E por direção, separando compra de venda.        |
//+------------------------------------------------------------------+
ulong GL_TicketAncora(CGLGrid &st)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((long)PositionGetInteger(POSITION_MAGIC) != st.magicAncora)
         continue;

      ENUM_POSITION_TYPE tipo = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(st.direcao == 1 && tipo != POSITION_TYPE_BUY)
         continue;
      if(st.direcao == -1 && tipo != POSITION_TYPE_SELL)
         continue;

      return(ticket);
     }

   return(0);
  }

//+------------------------------------------------------------------+
//| Localiza o ticket da sub-operação recém-aberta nesta perna.       |
//| Filtra pelo Magic exclusivo da perna para não misturar reentradas.|
//+------------------------------------------------------------------+
ulong GL_TicketRecemAberto(CGLGrid &st)
  {
   ulong melhor = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((long)PositionGetInteger(POSITION_MAGIC) != st.magicSub)
         continue;

      ENUM_POSITION_TYPE tipo = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(st.direcao == 1 && tipo != POSITION_TYPE_BUY)
         continue;
      if(st.direcao == -1 && tipo != POSITION_TYPE_SELL)
         continue;

      bool mapeado = false;
      for(int j = 0; j < ArraySize(st.nivelTicket); j++)
         if(st.nivelTicket[j] == ticket)
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
//| Verifica se ainda existe alguma posição ativa desta perna.        |
//| Considera a âncora (mesma direção) e as reentradas (Magic da perna)|
//+------------------------------------------------------------------+
bool GL_ExistePosicaoAtiva(CGLGrid &st)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long magic = (long)PositionGetInteger(POSITION_MAGIC);

      if(magic == st.magicSub)
         return(true);

      if(magic == st.magicAncora)
        {
         ENUM_POSITION_TYPE tipo = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if((st.direcao == 1 && tipo == POSITION_TYPE_BUY) ||
            (st.direcao == -1 && tipo == POSITION_TYPE_SELL))
            return(true);
        }
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Reinicia completamente o estado da grade virtual de uma perna.    |
//+------------------------------------------------------------------+
void ResetGL(CGLGrid &st, const string motivo = "")
  {
   if(st.ativo && motivo != "")
      Print("AlphaBot GL - Grade (", (st.direcao == 1 ? "COMPRA" : "VENDA"),
            ") encerrada. Motivo: ", motivo);

   st.ativo         = false;
   st.direcao       = 0;
   st.entrada       = 0.0;
   st.globalSL      = 0.0;
   st.globalTP      = 0.0;
   st.stepSL        = 0.0;
   st.stepTP        = 0.0;
   st.ultimaMetrica = 0.0;

   ArrayResize(st.nivelAberto, 0);
   ArrayResize(st.nivelTicket, 0);
  }

//+------------------------------------------------------------------+
//| Calcula os níveis da grade a partir do preço de entrada.          |
//| Deve ser chamada imediatamente após abrir a operação principal.   |
//+------------------------------------------------------------------+
void CalculateGLLevels(CGLGrid &st, const double precoEntrada, const int direcao)
  {
   if(!InpEnableGL)
      return;

   ResetGL(st);

   st.ativo   = true;
   st.direcao = direcao;
   st.entrada = precoEntrada;

//--- Distâncias globais e passo de cada nível
   double distanciaSL = InpStopLossGlobal * _Point;
   double distanciaTP = InpTakeProfitGlobal * _Point;

   st.stepSL = distanciaSL / MathMax(1, InpLevelsSL);
   st.stepTP = distanciaTP / MathMax(1, InpLevelsTP);

//--- Preços dos extremos (SL e TP globais) espelhados por direção
   if(direcao == 1)
     {
      st.globalSL = precoEntrada - distanciaSL;
      st.globalTP = precoEntrada + distanciaTP;
     }
   else
     {
      st.globalSL = precoEntrada + distanciaSL;
      st.globalTP = precoEntrada - distanciaTP;
     }

//--- A métrica inicial é zero (preço posicionado na entrada/nível 0)
   st.ultimaMetrica = 0.0;

//--- Alocação dos arrays da grade virtual
   int totalNiveis = InpLevelsSL + InpLevelsTP + 1;
   ArrayResize(st.nivelAberto, totalNiveis);
   ArrayResize(st.nivelTicket, totalNiveis);

   for(int i = 0; i < totalNiveis; i++)
     {
      st.nivelAberto[i] = false;
      st.nivelTicket[i] = 0;
     }

//--- Registra a operação principal como âncora do nível 0
   ulong ticketAncora = GL_TicketAncora(st);
   int   idx0         = GL_IndiceDoNivel(0);

   st.nivelAberto[idx0] = (ticketAncora != 0);
   st.nivelTicket[idx0] = ticketAncora;

   Print("=== GRADIENTE LINEAR ATIVADO ===");
   Print("AlphaBot GL - Direção: ", (direcao == 1 ? "COMPRA" : "VENDA"),
         " | Entrada: ", DoubleToString(precoEntrada, _Digits),
         " | Níveis SL: ", InpLevelsSL, " (passo ",
         DoubleToString(st.stepSL, _Digits), ")",
         " | Níveis TP: ", InpLevelsTP, " (passo ",
         DoubleToString(st.stepTP, _Digits), ")");
   Print("AlphaBot GL - Global SL: ", DoubleToString(st.globalSL, _Digits),
         " | Global TP: ", DoubleToString(st.globalTP, _Digits),
         " | Lote: ", DoubleToString(InpLoteInicial, 2),
         " | MagicSub: ", st.magicSub,
         " | Âncora: ", ticketAncora, ".");

//--- Verificação de espelhamento: na COMPRA o TP fica ACIMA e o drawdown ABAIXO;
//--- na VENDA ocorre o inverso (TP abaixo / drawdown acima).
   Print("AlphaBot GL - Espelhamento (", (direcao == 1 ? "COMPRA" : "VENDA"),
         ") | Nível +1 (TP)=", DoubleToString(GL_PrecoDoNivel(st, 1), _Digits),
         " | Nível -1 (drawdown)=", DoubleToString(GL_PrecoDoNivel(st, -1), _Digits),
         " | Referência=", DoubleToString(precoEntrada, _Digits), ".");
  }

//+------------------------------------------------------------------+
//| Sincroniza o estado: níveis cujos tickets foram fechados pelo     |
//| broker (TP/SL individuais) são liberados para eventual recompra.  |
//+------------------------------------------------------------------+
void GL_SincronizarEstado(CGLGrid &st)
  {
   int total = ArraySize(st.nivelAberto);

   for(int i = 0; i < total; i++)
     {
      if(!st.nivelAberto[i])
         continue;

      ulong ticket = st.nivelTicket[i];

      if(ticket == 0 || !PositionSelectByTicket(ticket))
        {
         st.nivelAberto[i] = false;
         st.nivelTicket[i] = 0;
        }
     }
  }

//+------------------------------------------------------------------+
//| Abre uma sub-operação a mercado no nível informado.               |
//| O Take Profit é posicionado no nível imediatamente acima (k+1).   |
//| O Stop Loss é o Stop Loss global da perna (proteção individual).  |
//+------------------------------------------------------------------+
bool GL_OpenPosition(CGLGrid &st, const int offset)
  {
   if(!st.ativo)
      return(false);

   int idx = GL_IndiceDoNivel(offset);
   if(idx < 0 || idx >= ArraySize(st.nivelAberto))
      return(false);

   if(st.nivelAberto[idx])
      return(false);

//--- Não abre no extremo do TP global (esse nível é de encerramento total)
   int offsetAlvo = offset + 1;
   if(offsetAlvo > InpLevelsTP)
      return(false);

   double tp  = NormalizeDouble(GL_PrecoDoNivel(st, offsetAlvo), _Digits);
   double sl  = NormalizeDouble(st.globalSL, _Digits);
   double lote= GL_NormalizarLote(InpLoteInicial);

   if(lote <= 0.0)
     {
      Print("AlphaBot GL - ERRO: lote inválido para o símbolo ", _Symbol, ".");
      return(false);
     }

   string comentario = "GL " + (st.direcao == 1 ? "BUY" : "SELL") +
                       " Nivel " + IntegerToString(offset);

//--- Usa SEMPRE o Magic exclusivo da perna nas reentradas
   trade.SetExpertMagicNumber(st.magicSub);

   bool ok = false;
   if(st.direcao == 1)
      ok = trade.Buy(lote, _Symbol, 0.0, sl, tp, comentario);
   else
      ok = trade.Sell(lote, _Symbol, 0.0, sl, tp, comentario);

   ulong ticket = 0;

   if(ok)
     {
      ticket = GL_TicketRecemAberto(st);
      if(ticket == 0)
         ticket = (ulong)trade.ResultOrder();

      st.nivelAberto[idx] = true;
      st.nivelTicket[idx] = ticket;

      Print("AlphaBot GL - Sub-operação aberta no nível ", offset,
            " (", (st.direcao == 1 ? "COMPRA" : "VENDA"), ")",
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
void GL_ClosePositionAt(CGLGrid &st, const int offset, const string motivo)
  {
   int idx = GL_IndiceDoNivel(offset);
   if(idx < 0 || idx >= ArraySize(st.nivelAberto))
      return;

   if(!st.nivelAberto[idx])
      return;

   ulong ticket = st.nivelTicket[idx];

   if(ticket == 0 || !PositionSelectByTicket(ticket))
     {
      st.nivelAberto[idx] = false;
      st.nivelTicket[idx] = 0;
      return;
     }

   if(trade.PositionClose(ticket))
      Print("AlphaBot GL - Nível ", offset, " encerrado no lucro (",
            motivo, ") | ticket=", ticket, ".");
   else
      Print("AlphaBot GL - ERRO ao encerrar nível ", offset, " | ticket=", ticket,
            ". Retcode=", trade.ResultRetcode(),
            " (", trade.ResultRetcodeDescription(), ").");

   st.nivelAberto[idx] = false;
   st.nivelTicket[idx] = 0;
  }

//+------------------------------------------------------------------+
//| ZONA DE DRAWDOWN / RECUO                                          |
//| A cada nível cruzado no sentido adverso, abre uma sub-operação    |
//| cujo TP aponta para o nível imediatamente superior.               |
//+------------------------------------------------------------------+
void CheckGLDrawdownZone(CGLGrid &st, const double prevM, const double curM)
  {
//--- Do nível mais profundo (sem tocar o SL global) até o penúltimo
//--- nível rumo ao TP. Inclui o nível 0 (recuo do lucro para a entrada).
   for(int offset = -(InpLevelsSL - 1); offset <= InpLevelsTP - 1; offset++)
     {
      if(!GL_CruzouAdverso(st, prevM, curM, offset))
         continue;

      Print("AlphaBot GL - Preço cruzou o nível ", offset,
            " (zona de drawdown/recuo). Engatilhando sub-operação.");
      GL_OpenPosition(st, offset);
     }
  }

//+------------------------------------------------------------------+
//| ZONA DE LUCRO (rolagem de posições)                               |
//| Ao atingir o nível k: fecha a posição de k-1 e abre/engatilha     |
//| nova posição em k, com TP no nível k+1 (regra de ouro da zona TP).|
//+------------------------------------------------------------------+
void CheckGLProfitZone(CGLGrid &st, const double prevM, const double curM)
  {
//--- Determina o nível mais alto alcançado neste movimento (trata gaps)
   int nivelMax = -1;
   for(int offset = 1; offset <= InpLevelsTP; offset++)
      if(GL_CruzouFavoravel(st, prevM, curM, offset))
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
      if(idx >= 0 && idx < ArraySize(st.nivelAberto) && st.nivelAberto[idx])
         GL_ClosePositionAt(st, offset,
                            "rolagem para o nível " + IntegerToString(nivelMax));
     }

//--- Regra de ouro: engatilha nova posição no nível alcançado rumo ao próximo
   GL_OpenPosition(st, nivelMax);
  }

//+------------------------------------------------------------------+
//| Encerra TODAS as posições de UMA perna (âncora + reentradas) e    |
//| coloca a grade da perna em modo de espera.                        |
//+------------------------------------------------------------------+
void CloseLegPositions(CGLGrid &st, const string motivo = "")
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
      bool pertence = false;

      if(magic == st.magicSub)
         pertence = true;
      else
         if(magic == st.magicAncora)
           {
            ENUM_POSITION_TYPE tipo = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if((st.direcao == 1 && tipo == POSITION_TYPE_BUY) ||
               (st.direcao == -1 && tipo == POSITION_TYPE_SELL))
               pertence = true;
           }

      if(!pertence)
         continue;

      if(trade.PositionClose(ticket))
         fechadas++;
      else
         Print("AlphaBot GL - ERRO no encerramento da perna | ticket=", ticket,
               ". Retcode=", trade.ResultRetcode(),
               " (", trade.ResultRetcodeDescription(), ").");
     }

   Print("AlphaBot GL - Perna ", (st.direcao == 1 ? "COMPRA" : "VENDA"),
         " encerrada (", motivo, "). Posições fechadas: ", fechadas, ".");

   ResetGL(st, motivo);
  }

//+------------------------------------------------------------------+
//| ENCERRAMENTO GLOBAL DE UMA PERNA                                  |
//| Ao tocar exatamente o SL ou TP global, fecha as posições da perna.|
//+------------------------------------------------------------------+
bool CheckGLGlobalClose(CGLGrid &st, const double curM)
  {
   double metricaTP = st.stepTP * InpLevelsTP;
   double metricaSL = -st.stepSL * InpLevelsSL;

   if(curM >= metricaTP)
     {
      Print("AlphaBot GL - TAKE PROFIT GLOBAL atingido (",
            DoubleToString(st.globalTP, _Digits), "). Encerramento da perna.");
      CloseLegPositions(st, "TP Global");
      return(true);
     }

   if(curM <= metricaSL)
     {
      Print("AlphaBot GL - STOP LOSS GLOBAL atingido (",
            DoubleToString(st.globalSL, _Digits), "). Encerramento da perna.");
      CloseLegPositions(st, "SL Global");
      return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Fecha TODAS as posições deste robô (todas as pernas) e zera as    |
//| grades virtuais. Usada pela proteção financeira global da cesta.  |
//+------------------------------------------------------------------+
void CloseAllRobotPositions(const string motivo = "")
  {
   int fechadas = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(!GL_MagicPertenceAoRobo((long)PositionGetInteger(POSITION_MAGIC)))
         continue;

      if(trade.PositionClose(ticket))
         fechadas++;
      else
         Print("AlphaBot - ERRO no encerramento total | ticket=", ticket,
               ". Retcode=", trade.ResultRetcode(),
               " (", trade.ResultRetcodeDescription(), ").");
     }

   Print("AlphaBot - Encerramento global executado (", motivo,
         "). Posições fechadas: ", fechadas, ".");

   ResetGL(g_glGrid, "");
   ResetGL(g_glBuy, "");
   ResetGL(g_glSell, "");
  }

//+------------------------------------------------------------------+
//| RE-SEED CONTÍNUO DE UMA PERNA                                     |
//| Mantém o Hedge Bidirecional SEMPRE com as duas grelhas vivas.      |
//| Quando a grade de uma perna se esgota (TP/SL global ou ausência de |
//| posições), abre uma NOVA âncora da MESMA direção ao preço atual e  |
//| recalcula a grade a partir dela. Sem isto, a perna morre e só a    |
//| outra continua a operar.                                          |
//+------------------------------------------------------------------+
bool GL_ReSeedLeg(CGLGrid &st, const int direcao)
  {
   if(!InpBidirectionalGrid)
      return(false);

//--- Throttle: no máximo uma tentativa a cada 2 segundos por perna
   datetime agora = TimeCurrent();
   if(st.ultimoReseed > 0 && (agora - st.ultimoReseed) < 2)
      return(false);
   st.ultimoReseed = agora;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return(false);

   double preco  = (direcao == 1) ? ask : bid;
   double distSL = InpStopLossGlobal   * _Point;
   double distTP = InpTakeProfitGlobal * _Point;
   double sl     = 0.0;
   double tp     = 0.0;

//--- COMPRA entra no ASK (SL abaixo / TP acima); VENDA entra no BID (SL acima / TP abaixo)
   if(direcao == 1)
     {
      sl = NormalizeDouble(preco - distSL, _Digits);
      tp = NormalizeDouble(preco + distTP, _Digits);
     }
   else
     {
      sl = NormalizeDouble(preco + distSL, _Digits);
      tp = NormalizeDouble(preco - distTP, _Digits);
     }

   trade.SetExpertMagicNumber(st.magicSub);

   bool ok = false;
   if(direcao == 1)
      ok = trade.Buy(InpLoteInicial, _Symbol, 0.0, sl, tp, "AlphaBot Hedge ReSeed BUY");
   else
      ok = trade.Sell(InpLoteInicial, _Symbol, 0.0, sl, tp, "AlphaBot Hedge ReSeed SELL");

   trade.SetExpertMagicNumber(InpMagicNumber);

   if(!ok)
     {
      Print("[GRID ", (direcao == 1 ? "COMPRA" : "VENDA"),
            "] RE-SEED FALHOU | retcode=", trade.ResultRetcode(),
            " (", trade.ResultRetcodeDescription(), ") | preço=",
            DoubleToString(preco, _Digits), ".");
      return(false);
     }

   Print("[GRID ", (direcao == 1 ? "COMPRA" : "VENDA"),
         "] RE-SEED: nova âncora | preço=", DoubleToString(preco, _Digits),
         " | SL=", DoubleToString(sl, _Digits),
         " | TP=", DoubleToString(tp, _Digits),
         " | ticket=", trade.ResultOrder(), ".");

//--- Reativa a grade da perna a partir do novo preço base
   CalculateGLLevels(st, preco, direcao);
   return(true);
  }

//+------------------------------------------------------------------+
//| Log de depuração agressivo e periódico de uma grelha.             |
//| Mostra o preço, a métrica e os próximos níveis de Drawdown e TP.  |
//+------------------------------------------------------------------+
void GL_LogEstado(CGLGrid &st, const double preco, const double curM,
                  const string estado, const bool forcar = false)
  {
   datetime agora = TimeCurrent();
   if(!forcar && st.ultimoLog > 0 && (agora - st.ultimoLog) < 60)
      return;
   st.ultimoLog = agora;

//--- Próximo nível de drawdown (adverso) ainda não cruzado
   int proxDD = (InpLevelsSL > 0) ? -InpLevelsSL : 0;
   for(int k = -1; k >= -InpLevelsSL; k--)
      if(GL_MetricaDoNivel(st, k) < curM)
        {
         proxDD = k;
         break;
        }

//--- Próximo nível de lucro (favorável) ainda não cruzado
   int proxTP = (InpLevelsTP > 0) ? InpLevelsTP : 0;
   for(int k = 1; k <= InpLevelsTP; k++)
      if(GL_MetricaDoNivel(st, k) > curM)
        {
         proxTP = k;
         break;
        }

//--- Na COMPRA o drawdown fica ABAIXO e o TP ACIMA; na VENDA é o inverso.
   string rotDD = (st.direcao == 1) ? "Inferior" : "Superior";
   string rotTP = (st.direcao == 1) ? "Superior" : "Inferior";

   Print("[GRID ", (st.direcao == 1 ? "COMPRA" : "VENDA"),
         "] Preço Atual: ", DoubleToString(preco, _Digits),
         " | Métrica: ", DoubleToString(curM, _Digits),
         " | Nível ", rotDD, " (Drawdown): ",
         DoubleToString(GL_PrecoDoNivel(st, proxDD), _Digits), " (", proxDD, ")",
         " | Nível ", rotTP, " (TP): ",
         DoubleToString(GL_PrecoDoNivel(st, proxTP), _Digits), " (", proxTP, ")",
         " | Estado: ", estado, ".");
  }

//+------------------------------------------------------------------+
//| Orquestrador do Gradiente Linear de UMA perna, chamado a cada tick.|
//+------------------------------------------------------------------+
void ManageGradient(CGLGrid &st)
  {
   if(!st.ativo)
      return;

   double preco = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(preco <= 0.0)
      return;

   int    dir   = st.direcao;
   double curM  = GL_MetricaDoPreco(st, preco);
   double prevM = st.ultimaMetrica;

//--- Libera níveis fechados pelo broker (TP/SL individuais)
   GL_SincronizarEstado(st);

//--- Encerramento global prioritário
   if(CheckGLGlobalClose(st, curM))
     {
      //--- Hedge contínuo: re-semeia a perna que completou, mantendo as duas grelhas vivas
      if(InpBidirectionalGrid)
         GL_ReSeedLeg(st, dir);

      return;
     }

//--- Grade exaurida (sem posições ativas)
   if(!GL_ExistePosicaoAtiva(st))
     {
      if(InpBidirectionalGrid)
        {
         Print("[GRID ", (dir == 1 ? "COMPRA" : "VENDA"),
               "] Grade sem posições ativas -> RE-SEED para manter o hedge contínuo.");
         GL_ReSeedLeg(st, dir);
        }
      else
        {
         Print("AlphaBot GL - Nenhuma posição ativa na perna ",
               (dir == 1 ? "COMPRA" : "VENDA"),
               ". Grade encerrada; aguardando novo sinal técnico.");
         ResetGL(st, "Sem posições ativas.");
        }

      return;
     }

//--- Avaliação dos cruzamentos de níveis nas duas zonas
   CheckGLDrawdownZone(st, prevM, curM);
   CheckGLProfitZone(st, prevM, curM);

   st.ultimaMetrica = curM;

//--- Log de depuração (periódico) com os próximos níveis desta perna
   GL_LogEstado(st, preco, st.ultimaMetrica, "Aguardando próximo nível");
  }

//+------------------------------------------------------------------+
//| Existe alguma posição (âncora ou reentrada) deste robô no símbolo?|
//+------------------------------------------------------------------+
bool ExistePosicaoRobo()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(GL_MagicPertenceAoRobo((long)PositionGetInteger(POSITION_MAGIC)))
         return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| PROTEÇÃO FINANCEIRA GLOBAL (CESTA DE ORDENS)                      |
//| Soma o lucro/prejuízo flutuante de TODAS as posições do robô. Se  |
//| atingir o Alvo de Lucro ou a Perda Máxima, fecha tudo a mercado e |
//| zera as grades virtuais.                                          |
//+------------------------------------------------------------------+
bool CheckGlobalHedgeExit()
  {
   double lucroTotal = 0.0;
   int    posicoes    = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(!GL_MagicPertenceAoRobo((long)PositionGetInteger(POSITION_MAGIC)))
         continue;

      lucroTotal += PositionGetDouble(POSITION_PROFIT)
                  + PositionGetDouble(POSITION_SWAP);
      posicoes++;
     }

   if(posicoes == 0)
      return(false);

   bool alvoLucro   = (InpTargetProfitMoney > 0.0 && lucroTotal >= InpTargetProfitMoney);
   bool perdaMaxima = (InpMaxDrawdownMoney  > 0.0 && lucroTotal <= -MathAbs(InpMaxDrawdownMoney));

   if(!alvoLucro && !perdaMaxima)
      return(false);

   Print("AlphaBot HEDGE - CESTA encerrada. P/L flutuante=",
         DoubleToString(lucroTotal, 2), " | Posições=", posicoes,
         " | Motivo: ", (alvoLucro ? "Alvo de Lucro Global" : "Perda Máxima Global"), ".");

   CloseAllRobotPositions(alvoLucro ? "Alvo de Lucro Global" : "Perda Máxima Global");
   return(true);
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
         CalculateGLLevels(g_glGrid, trade.ResultPrice(), 1);
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
         CalculateGLLevels(g_glGrid, trade.ResultPrice(), -1);
     }
   else
     {
      Print("AlphaBot - ERRO ao enviar ordem de VENDA. Retcode: ",
            trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(),
            ") | Erro: ", GetLastError());
     }
  }

//+------------------------------------------------------------------+
//| Existe alguma posição aberta deste robô com o Magic informado?    |
//+------------------------------------------------------------------+
bool ExistePosicaoComMagic(const long magic)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((long)PositionGetInteger(POSITION_MAGIC) == magic)
         return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Envia UMA perna do Hedge a mercado, com Magic próprio, e loga     |
//| SEMPRE o código de retorno e a descrição (sucesso ou falha).      |
//+------------------------------------------------------------------+
bool EnviarPernaHedge(const ENUM_ORDER_TYPE tipo, const long magic,
                      const double sl, const double tp, const string rotulo)
  {
   trade.SetExpertMagicNumber(magic);

   bool ok = false;
   if(tipo == ORDER_TYPE_BUY)
      ok = trade.Buy(InpLoteInicial, _Symbol, 0.0, sl, tp, rotulo);
   else
      ok = trade.Sell(InpLoteInicial, _Symbol, 0.0, sl, tp, rotulo);

   Print("AlphaBot HEDGE - Ordem ", rotulo,
         " | tipo=", EnumToString(tipo),
         " | lote=", DoubleToString(InpLoteInicial, 2),
         " | SL=", DoubleToString(sl, _Digits),
         " | TP=", DoubleToString(tp, _Digits),
         " | preço=", DoubleToString(trade.ResultPrice(), _Digits),
         " | order=", trade.ResultOrder(),
         " | deal=", trade.ResultDeal(),
         " | retcode=", trade.ResultRetcode(),
         " (", trade.ResultRetcodeDescription(), ")",
         " | status=", (ok ? "ENVIADA" : "FALHOU"));

   if(ok && !ExistePosicaoComMagic(magic))
      Print("AlphaBot HEDGE - AVISO: ordem ", rotulo,
            " retornou sucesso, mas nenhuma posição com Magic ", magic,
            " foi encontrada. Posições do robô no símbolo: ", PositionsTotal(), ".");

   return(ok);
  }

//+------------------------------------------------------------------+
//| GRID BIDIRECIONAL COM HEDGE                                       |
//| Abre simultaneamente UMA COMPRA e UMA VENDA a mercado, ambas com  |
//| o mesmo preço base, e ativa o Gradiente Linear espelhado em cada  |
//| perna (cada uma com seu Magic exclusivo).                         |
//+------------------------------------------------------------------+
void ExecuteBidirectionalEntry()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(ask <= 0.0 || bid <= 0.0)
     {
      Print("AlphaBot - ERRO: preços inválidos para abertura Hedge (Ask=",
            DoubleToString(ask, _Digits), " | Bid=", DoubleToString(bid, _Digits), ").");
      return;
     }

//--- Preço base comum às duas pernas do Gradiente Linear (grade virtual)
   double precoBase = NormalizeDouble((ask + bid) / 2.0, _Digits);

//--- SL/TP calculados a partir do preço de execução REAL de cada perna:
//---   COMPRA entra no ASK -> SL abaixo / TP acima.
//---   VENDA  entra no BID -> SL acima  / TP abaixo.
   double slCompra = NormalizeDouble(ask - InpStopLossGlobal   * _Point, _Digits);
   double tpCompra = NormalizeDouble(ask + InpTakeProfitGlobal * _Point, _Digits);
   double slVenda  = NormalizeDouble(bid + InpStopLossGlobal   * _Point, _Digits);
   double tpVenda  = NormalizeDouble(bid - InpTakeProfitGlobal * _Point, _Digits);

   Print("Tentando abrir Hedge Duplo: Preço ", DoubleToString(precoBase, _Digits),
         " | TP Compra ", DoubleToString(tpCompra, _Digits),
         " / SL Compra ", DoubleToString(slCompra, _Digits),
         " | TP Venda ", DoubleToString(tpVenda, _Digits),
         " / SL Venda ", DoubleToString(slVenda, _Digits));

//--- Perna de COMPRA (Magic próprio: InpMagicGLBuy)
   bool okCompra = EnviarPernaHedge(ORDER_TYPE_BUY, InpMagicGLBuy,
                                    slCompra, tpCompra, "AlphaBot Hedge Compra");

//--- Perna de VENDA (Magic próprio: InpMagicGLSell)
   bool okVenda = EnviarPernaHedge(ORDER_TYPE_SELL, InpMagicGLSell,
                                   slVenda, tpVenda, "AlphaBot Hedge Venda");

//--- Restaura o Magic padrão das operações normais
   trade.SetExpertMagicNumber(InpMagicNumber);

   if(!okCompra)
      Print("AlphaBot HEDGE - ATENÇÃO: perna de COMPRA NÃO foi aberta. ",
            "Verifique saldo/margem, modo de preenchimento e nível mínimo de stops.");

   if(!okVenda)
      Print("AlphaBot HEDGE - ATENÇÃO: perna de VENDA NÃO foi aberta. ",
            "Verifique saldo/margem, modo de preenchimento e nível mínimo de stops.");

   if(!InpEnableGL)
      return;

//--- Ativa o Gradiente Linear espelhado a partir do MESMO preço base
   if(okCompra)
      CalculateGLLevels(g_glBuy, precoBase, 1);

   if(okVenda)
      CalculateGLLevels(g_glSell, precoBase, -1);

//--- Sessão de Hedge iniciada: a partir daqui as DUAS grelhas são mantidas vivas
   g_hedgeAtivo = true;
   Print("AlphaBot HEDGE - Sessão bidirecional iniciada. As duas grelhas serão mantidas ativas.");
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- GRID BIDIRECIONAL: proteção da cesta + gestão PARALELA das duas grelhas
   if(InpBidirectionalGrid)
     {
      //--- Proteção financeira global (cesta). Se disparar, encerra a sessão de hedge
      if(ExistePosicaoRobo() && CheckGlobalHedgeExit())
        {
         g_hedgeAtivo = false;
         return;
        }

      //--- Sessão já iniciada: mantém SEMPRE as duas pernas vivas e processa ambas
      if(g_hedgeAtivo)
        {
         //--- Re-semeia qualquer perna que tenha sido encerrada/esgotada
         if(!g_glBuy.ativo)
            GL_ReSeedLeg(g_glBuy, 1);

         if(!g_glSell.ativo)
            GL_ReSeedLeg(g_glSell, -1);

         //--- Gestão independente e incondicional das DUAS grelhas (sem return entre elas)
         ManageGradient(g_glBuy);
         ManageGradient(g_glSell);
         return;
        }

      //--- Ainda não iniciada, mas há posições do robô: não aplica lógica de posição única
      if(ExistePosicaoRobo())
         return;
     }
   else
     {
      //--- Gradiente Linear unidirecional ativo: gerencia a grade virtual
      if(g_glGrid.ativo)
        {
         ManageGradient(g_glGrid);
         return;
        }
     }

//--- Avalia o price action do candle [1] + filtro de tendência macro
   ENUM_ALPHA_SIGNAL sinal=CheckPriceActionSignal();

   if(sinal==SIGNAL_NONE)
      return;

   int direcaoAtual=GetOpenPositionDirection();

//--- Sem posição aberta: abre na direção do sinal
   if(direcaoAtual==0)
     {
      if(InpBidirectionalGrid)
        {
         ExecuteBidirectionalEntry();
         return;
        }

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
  }
//+------------------------------------------------------------------+
