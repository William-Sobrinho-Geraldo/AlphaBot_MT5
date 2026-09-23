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
//| Prefixo dos objetos gráficos do Motor Fimathe                    |
//+------------------------------------------------------------------+
#define FIMATHE_PREFIX "Fimathe_Obj_"

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
//| Estratégia responsável por gerar o gatilho da primeira ordem      |
//+------------------------------------------------------------------+
enum ENUM_ENTRY_SIGNAL_TYPE
  {
   SIGNAL_CANDLE_PATTERNS, // Padrões de Candle (Engolfo, Martelo)
   SIGNAL_FIMATHE,         // Metodologia Fimathe (Rompimento CR + ZN)
   SIGNAL_TRAP             // Armadilha de Liquidez / Wyckoff (Fake Breakout + Volume)
  };

//+------------------------------------------------------------------+
//| Modo de cálculo da amplitude do canal Fimathe                    |
//+------------------------------------------------------------------+
enum ENUM_FIMATHE_CALC
  {
   FIMATHE_USE_SWING_BARS, // Estrutura de Velas (Pernada / Recuo)
   FIMATHE_USE_ATR         // ATR (Amplitude do Canal)
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

input group "=== AlphaBot - Motor de Sinal de Entrada ==="
input ENUM_ENTRY_SIGNAL_TYPE InpEntrySignalType = SIGNAL_FIMATHE; // Tipo de Sinal de Entrada
input int    InpFimatheATRPeriod    = 14;   // Fimathe: Período do ATR (Amplitude do Canal)
input double InpFimatheATRMult      = 1.5;  // Fimathe: Multiplicador do ATR (Altura do CR/ZN)
input ENUM_FIMATHE_CALC InpFimatheCalcType = FIMATHE_USE_SWING_BARS; // Fimathe: Modo de Cálculo do Canal
input int    InpFimatheSwingBars    = 10;   // Fimathe: Qtd de Velas da Pernada/Recuo (Se usar Swing)
input bool   InpUseSubcycleProtect  = true; // Fimathe: Breakeven no 1º Subciclo (1 Canal)
input bool   InpAllowFimatheReversal = true; // Fimathe: Virar a Mão (Reversão Automática ao romper ZN)

input group "=== AlphaBot - Armadilha de Liquidez (Wyckoff) ==="
input int    InpTrapLookback        = 20;   // Armadilha: Velas para buscar Topo/Fundo (Suporte/Resistência)
input double InpTrapVolMultiplier   = 1.5;  // Armadilha: Multiplicador de Volume de Absorção (vs Média)
input int    InpTrapVolMAPeriod     = 20;   // Armadilha: Período da Média Móvel de Volume
input double InpTrapRiskReward      = 2.0;  // Armadilha: Relação Risco x Retorno (TP / SL)
input double InpTrapStopBufferPips  = 2.0;  // Armadilha: Folga de Stop (Pips) além do Pavio

input group "=== AlphaBot - Execução de Ordens ==="
input long   InpMagicNumber    = 123456; // Magic Number
input ENUM_OPPOSITE_ACTION InpOppositeAction = ACTION_CLOSE_AND_REVERSE; // Ação em sinal oposto

input group "=== AlphaBot - Gradiente Linear (Grid Dinâmico) ==="
input bool   InpEnableGL  = true;   // Ativar Gradiente Linear?
input int    InpLevelsSL  = 4;      // Número de Níveis entre Entrada e Stop Loss
input int    InpLevelsTP  = 4;      // Número de Níveis entre Entrada e Take Profit
input long   InpMagicGL   = 654321; // Magic Number exclusivo das posições do Gradiente

input group "=== AlphaBot - Piramidagem (Gradiente Positivo) ==="
input bool   InpEnablePositivePyramid = true; // Ativar Piramidagem no Gradiente Positivo
input double InpPositiveLotBase       = 0.02; // Volume total na abertura (Níveis Positivos)
input double InpPartialCloseVolume    = 0.01; // Volume a ser fechado no alvo (Parcial)

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
int    g_handle_atr      = INVALID_HANDLE; // Handle do ATR do Motor Fimathe

string g_signalPadrao = ""; // Nome do padrão que gerou o último sinal

bool   g_hedgeAtivo = false; // Sessão de Hedge Bidirecional iniciada? (mantém as 2 grelhas vivas)

//--- Estado do Motor Fimathe (proteção de subciclo / Breakeven)
bool   g_entradaFimathe       = false; // A posição-âncora atual foi gerada pela Fimathe?
bool   g_fimatheBEFeito       = false; // O Breakeven do 1º subciclo já foi aplicado?
ulong  g_fimatheAnchorTicket  = 0;     // Ticket da posição-âncora gerada pela Fimathe
double g_fimatheChannelHeight = 0.0;   // Altura do canal (em preço) do sinal Fimathe vigente

//--- Estado da visualização gráfica dos canais Fimathe
bool   g_fimatheGraficoAtivo  = false; // Há linhas do Fimathe desenhadas no gráfico?

//--- Canais Fimathe ESTÁTICOS (fixados até ocorrer rompimento + ordem aberta)
double g_fimatheCRTop           = 0.0; // Borda superior do Canal de Referência
double g_fimatheCRBottom        = 0.0; // Borda inferior do CR / Divisória CR-ZN
double g_fimatheZNBottom        = 0.0; // Borda inferior da Zona Neutra (tendência de ALTA)
double g_fimatheZNTop           = 0.0; // Borda superior da Zona Neutra (tendência de BAIXA)
bool   g_fimatheCanalAlta       = true;// Orientação do canal: true=ALTA (ZN abaixo), false=BAIXA (ZN acima)
bool   g_fimatheCanaisDefinidos = false; // Os canais já foram fixados neste ciclo?
bool   g_fimatheTinhaPosicao    = false; // O ciclo chegou a ter posição ativa? (transição)
datetime g_fimatheUltimaBarraLog = 0;    // Anti-spam do log de aguardo (1x por candle)

//--- Estado do Motor Armadilha de Liquidez / Wyckoff
bool   g_trapAtivo               = false; // O sinal pendente é da Armadilha?
double g_trapStopLoss            = 0.0;   // Stop Loss calculado pelo pavio (armadilha)
datetime g_trapUltimaBarraAvaliada = 0;   // Controle: avalia apenas 1x por candle fechado

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
   bool   nivelPositivo[];// Nível aberto como reentrada do Gradiente Positivo (piramidagem)?
   bool   nivelParcial[]; // Fechamento parcial (Virtual TP) já executado neste nível?
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
//| Cria e valida o handle do ATR usado pelo Motor Fimathe.           |
//+------------------------------------------------------------------+
bool InitFimatheATR()
  {
   g_handle_atr=iATR(_Symbol, PERIOD_CURRENT, InpFimatheATRPeriod);
   if(g_handle_atr==INVALID_HANDLE)
     {
      Print("AlphaBot FIMATHE - ERRO: falha ao criar handle do ATR ",
            InpFimatheATRPeriod, " (erro ", GetLastError(), ").");
      return(false);
     }

   Print("AlphaBot FIMATHE - ATR inicializado (período=", InpFimatheATRPeriod,
         " | multiplicador=", DoubleToString(InpFimatheATRMult, 2), ").");
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

//--- Validação dos parâmetros da Piramidagem do Gradiente Positivo
   if(InpEnablePositivePyramid)
     {
      if(InpPositiveLotBase <= 0.0 || InpPartialCloseVolume <= 0.0 ||
         InpPartialCloseVolume >= InpPositiveLotBase)
        {
         Alert("AlphaBot - ERRO: parâmetros inválidos da Piramidagem do Gradiente Positivo. ",
               "Exige InpPositiveLotBase > InpPartialCloseVolume > 0. Robô NÃO carregado.");
         Print("AlphaBot - OnInit abortado: Piramidagem inválida (lote base=",
               DoubleToString(InpPositiveLotBase, 2), " | parcial=",
               DoubleToString(InpPartialCloseVolume, 2), ").");
         return(INIT_FAILED);
        }
     }

//--- Criação e validação do handle da Média Móvel Macro
   if(!InitMediaMacro())
     {
      Alert("AlphaBot - ERRO: falha ao inicializar a Média Macro. Robô NÃO carregado.");
      return(INIT_FAILED);
     }

//--- Validação dos parâmetros do Motor de Sinal Fimathe
   if(InpEntrySignalType == SIGNAL_FIMATHE)
     {
      if(InpFimatheCalcType == FIMATHE_USE_ATR)
        {
         if(InpFimatheATRPeriod <= 0 || InpFimatheATRMult <= 0.0)
           {
            Alert("AlphaBot - ERRO: parâmetros inválidos do Motor Fimathe (modo ATR). ",
                  "Exige InpFimatheATRPeriod > 0 e InpFimatheATRMult > 0. Robô NÃO carregado.");
            Print("AlphaBot - OnInit abortado: Fimathe ATR inválida (ATR=",
                  InpFimatheATRPeriod, " | mult=",
                  DoubleToString(InpFimatheATRMult, 2), ").");
            return(INIT_FAILED);
           }

         //--- Criação e validação do handle do ATR (apenas no modo ATR)
         if(!InitFimatheATR())
           {
            Alert("AlphaBot - ERRO: falha ao inicializar o ATR do Motor Fimathe. Robô NÃO carregado.");
            return(INIT_FAILED);
           }
        }
      else
        {
         if(InpFimatheSwingBars < 2)
           {
            Alert("AlphaBot - ERRO: parâmetros inválidos do Motor Fimathe (modo Swing). ",
                  "Exige InpFimatheSwingBars >= 2. Robô NÃO carregado.");
            Print("AlphaBot - OnInit abortado: Fimathe Swing inválida (SwingBars=",
                  InpFimatheSwingBars, ").");
            return(INIT_FAILED);
           }
        }
     }

//--- Validação dos parâmetros da Armadilha de Liquidez / Wyckoff
   if(InpEntrySignalType == SIGNAL_TRAP)
     {
      if(InpTrapLookback < 2 || InpTrapVolMAPeriod < 2 ||
         InpTrapVolMultiplier <= 0.0 || InpTrapRiskReward <= 0.0 ||
         InpTrapStopBufferPips < 0.0)
        {
         Alert("AlphaBot - ERRO: parâmetros inválidos da Armadilha de Liquidez. ",
               "Exige InpTrapLookback >= 2, InpTrapVolMAPeriod >= 2, ",
               "InpTrapVolMultiplier > 0, InpTrapRiskReward > 0 e InpTrapStopBufferPips >= 0. ",
               "Robô NÃO carregado.");
         Print("AlphaBot - OnInit abortado: Armadilha inválida (lookback=",
               InpTrapLookback, " | volMA=", InpTrapVolMAPeriod,
               " | volMult=", DoubleToString(InpTrapVolMultiplier, 2),
               " | RR=", DoubleToString(InpTrapRiskReward, 2),
               " | buffer=", DoubleToString(InpTrapStopBufferPips, 2), ").");
         return(INIT_FAILED);
        }
     }

//--- Configuração do objeto de execução
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);

//--- Garante a exibição das descrições dos objetos gráficos (Fimathe)
   if(!ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, true))
      Print("AlphaBot - AVISO: não foi possível ativar CHART_SHOW_OBJECT_DESCR (erro ",
            GetLastError(), ").");

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
   Print("AlphaBot - Motor de Sinal de Entrada: ", EnumToString(InpEntrySignalType), ".");
   if(InpEntrySignalType == SIGNAL_FIMATHE)
     {
      if(InpFimatheCalcType == FIMATHE_USE_ATR)
         Print("AlphaBot FIMATHE - Cálculo=ATR (período=", InpFimatheATRPeriod,
               " | mult=", DoubleToString(InpFimatheATRMult, 2), ").");
      else
         Print("AlphaBot FIMATHE - Cálculo=SWING (velas da pernada/recuo=",
               InpFimatheSwingBars, ").");
      Print("AlphaBot FIMATHE - Breakeven 1º subciclo=",
            (InpUseSubcycleProtect ? "ON" : "OFF"),
            " | Reversão (Virar a Mão)=",
            (InpAllowFimatheReversal ? "ON" : "OFF"), ".");
     }
   if(InpEntrySignalType == SIGNAL_TRAP)
      Print("AlphaBot ARMADILHA - Lookback=", InpTrapLookback,
            " | VolMA=", InpTrapVolMAPeriod,
            " | VolMult=", DoubleToString(InpTrapVolMultiplier, 2),
            " | R:R=", DoubleToString(InpTrapRiskReward, 2),
            " | Buffer(pips)=", DoubleToString(InpTrapStopBufferPips, 2), ".");
   Print("AlphaBot - Ação em sinal oposto: ", EnumToString(InpOppositeAction), ".");
   Print("AlphaBot - Gradiente Linear: ", (InpEnableGL ? "ATIVO" : "INATIVO"),
         " (níveis SL=", InpLevelsSL, " | níveis TP=", InpLevelsTP,
         " | lote=", DoubleToString(InpLoteInicial, 2),
         " | MagicGL=", InpMagicGL, ").");
   Print("AlphaBot - Piramidagem (Gradiente Positivo): ",
         (InpEnablePositivePyramid ? "ATIVA" : "INATIVA"),
         " (lote base=", DoubleToString(InpPositiveLotBase, 2),
         " | parcial=", DoubleToString(InpPartialCloseVolume, 2),
         " | SL nativo 1 nível atrás, sem TP nativo).");
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

   if(g_handle_atr!=INVALID_HANDLE)
     {
      IndicatorRelease(g_handle_atr);
      g_handle_atr=INVALID_HANDLE;
     }

//--- Remove as linhas do Fimathe ao remover o robô / trocar de timeframe
   ClearFimatheChannels();

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

//+==================================================================+
//|              VISUALIZAÇÃO GRÁFICA DOS CANAIS FIMATHE              |
//+==================================================================+

//+------------------------------------------------------------------+
//| Cria/atualiza as linhas do Canal de Referência (CR) e da Zona     |
//| Neutra (ZN) no gráfico. Usa ObjectFind para não recriar objetos   |
//| já existentes a cada tick.                                        |
//+------------------------------------------------------------------+
void DrawFimatheChannels(const double crTopo, const double crBottom, const double znOuter, const bool canalAlta)
  {
   string nomeTopo  = FIMATHE_PREFIX + "CR_Topo";
   string nomeDiv   = FIMATHE_PREFIX + "CR_ZN_Divisoria";
   string nomeZn    = FIMATHE_PREFIX + "ZN_Fundo";
   string nomeTxtCR = FIMATHE_PREFIX + "Txt_CR";
   string nomeTxtZN = FIMATHE_PREFIX + "Txt_ZN";

//--- Garante que o MT5 exiba as descrições dos objetos no gráfico
   ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, true);

//--- Linha superior do Canal de Referência (CR)
   if(ObjectFind(0, nomeTopo) < 0)
     {
      ObjectCreate(0, nomeTopo, OBJ_HLINE, 0, 0, crTopo);
      ObjectSetInteger(0, nomeTopo, OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, nomeTopo, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, nomeTopo, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, nomeTopo, OBJPROP_BACK, true);
      ObjectSetInteger(0, nomeTopo, OBJPROP_SELECTABLE, false);
     }
   else
      ObjectSetDouble(0, nomeTopo, OBJPROP_PRICE, 0, crTopo);
   ObjectSetString(0, nomeTopo, OBJPROP_TEXT, "FIMATHE: Topo CR (Gatilho de COMPRA)");

//--- Divisória entre o CR e a ZN
   if(ObjectFind(0, nomeDiv) < 0)
     {
      ObjectCreate(0, nomeDiv, OBJ_HLINE, 0, 0, crBottom);
      ObjectSetInteger(0, nomeDiv, OBJPROP_COLOR, clrYellow);
      ObjectSetInteger(0, nomeDiv, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, nomeDiv, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, nomeDiv, OBJPROP_BACK, true);
      ObjectSetInteger(0, nomeDiv, OBJPROP_SELECTABLE, false);
     }
   else
      ObjectSetDouble(0, nomeDiv, OBJPROP_PRICE, 0, crBottom);
   ObjectSetString(0, nomeDiv, OBJPROP_TEXT, "FIMATHE: Divisória (CR / ZN)");

//--- Borda externa da Zona Neutra (ZN)
   if(ObjectFind(0, nomeZn) < 0)
     {
      ObjectCreate(0, nomeZn, OBJ_HLINE, 0, 0, znOuter);
      ObjectSetInteger(0, nomeZn, OBJPROP_COLOR, clrOrangeRed);
      ObjectSetInteger(0, nomeZn, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, nomeZn, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, nomeZn, OBJPROP_BACK, true);
      ObjectSetInteger(0, nomeZn, OBJPROP_SELECTABLE, false);
     }
   else
      ObjectSetDouble(0, nomeZn, OBJPROP_PRICE, 0, znOuter);
   ObjectSetString(0, nomeZn, OBJPROP_TEXT,
                   (canalAlta ? "FIMATHE: Fundo ZN (Gatilho de VENDA)"
                              : "FIMATHE: Topo ZN (Gatilho de COMPRA)"));

//--- Rótulos das regiões, ancorados próximos ao candle atual (lado direito)
   datetime tempoAncora = iTime(_Symbol, PERIOD_CURRENT, 0);
   double   meioCR      = (crTopo + crBottom) / 2.0;
   double   meioZN      = (crBottom + znOuter) / 2.0;

//--- Texto no meio do Canal de Referência
   if(ObjectFind(0, nomeTxtCR) < 0)
     {
      ObjectCreate(0, nomeTxtCR, OBJ_TEXT, 0, tempoAncora, meioCR);
      ObjectSetInteger(0, nomeTxtCR, OBJPROP_ANCHOR, ANCHOR_RIGHT);
      ObjectSetInteger(0, nomeTxtCR, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nomeTxtCR, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, nomeTxtCR, OBJPROP_TIME, 0, tempoAncora);
   ObjectSetDouble(0, nomeTxtCR, OBJPROP_PRICE, 0, meioCR);
   ObjectSetInteger(0, nomeTxtCR, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, nomeTxtCR, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, nomeTxtCR, OBJPROP_FONT, "Arial Bold");
   ObjectSetString(0, nomeTxtCR, OBJPROP_TEXT, "[ CANAL DE REFERÊNCIA ]");

//--- Texto no meio da Zona Neutra
   if(ObjectFind(0, nomeTxtZN) < 0)
     {
      ObjectCreate(0, nomeTxtZN, OBJ_TEXT, 0, tempoAncora, meioZN);
      ObjectSetInteger(0, nomeTxtZN, OBJPROP_ANCHOR, ANCHOR_RIGHT);
      ObjectSetInteger(0, nomeTxtZN, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nomeTxtZN, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, nomeTxtZN, OBJPROP_TIME, 0, tempoAncora);
   ObjectSetDouble(0, nomeTxtZN, OBJPROP_PRICE, 0, meioZN);
   ObjectSetInteger(0, nomeTxtZN, OBJPROP_COLOR, clrOrange);
   ObjectSetInteger(0, nomeTxtZN, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, nomeTxtZN, OBJPROP_FONT, "Arial Bold");
   ObjectSetString(0, nomeTxtZN, OBJPROP_TEXT, "[ ZONA NEUTRA - PROIBIDO OPERAR ]");

   g_fimatheGraficoAtivo = true;

   Print("[FIMATHE GRAPHICS] Canais desenhados (",
         (canalAlta ? "ALTA" : "BAIXA"), ") -> CR Topo: ",
         DoubleToString(crTopo, _Digits), " | CR Fundo: ",
         DoubleToString(crBottom, _Digits), " | ZN Externo: ",
         DoubleToString(znOuter, _Digits));
  }

//+------------------------------------------------------------------+
//| Remove TODAS as linhas gráficas do Fimathe (prefixo dedicado).    |
//+------------------------------------------------------------------+
void ClearFimatheChannels()
  {
   ObjectsDeleteAll(0, FIMATHE_PREFIX);
   g_fimatheGraficoAtivo = false;

//--- Libera os canais para que um novo setup seja fixado no próximo ciclo
   g_fimatheCanaisDefinidos = false;
   g_fimatheUltimaBarraLog  = 0;
  }

//+==================================================================+
//|              MOTOR DE SINAL FIMATHE (Rompimento CR + ZN)          |
//|                                                                    |
//| O bloco CR+ZN tem altura definida por estrutura de preço (pernada/ |
//| recuo) OU por ATR. O CR vai da mínima à máxima da pernada; a ZN é o |
//| canal contíguo de mesma altura, posicionado conforme a tendência:   |
//|   ALTA : ZN abaixo do CR  |  BAIXA : ZN acima do CR                 |
//|                                                                    |
//| REGRA DE OURO: os canais são FIXOS (estáticos) e NÃO se recalculam |
//| a cada tick. Só são redefinidos após um rompimento válido que      |
//| resulte em ordem aberta (ou no fim do ciclo).                      |
//|                                                                    |
//| Gatilhos estritos no FECHAMENTO dos candles (índice nativo MT5):   |
//|   COMPRA: rates[1].close >  BandTop    E rates[2].close <= BandTop |
//|   VENDA : rates[1].close <  BandBottom E rates[2].close >= BandBottom|
//|   ZONA NEUTRA: BandBottom <= rates[1].close <= BandTop -> SEM TRADE|
//+==================================================================+

//+------------------------------------------------------------------+
//| Fixa (uma única vez) os canais CR e ZN. A amplitude vem da        |
//| estrutura de preço (pernada/recuo) OU do ATR, conforme o input.   |
//| A partir daqui os níveis ficam ESTÁTICOS até que ocorra rompimento|
//| e uma ordem seja aberta.                                          |
//+------------------------------------------------------------------+
bool FimatheDefinirCanais()
  {
   double channelHeight = 0.0;
   double crTopo        = 0.0;
   double crBottom      = 0.0;
   bool   canalAlta     = true;

   if(InpFimatheCalcType == FIMATHE_USE_ATR)
     {
      //--- AMPLITUDE VIA ATR: topo do CR na máxima do último candle fechado
      if(g_handle_atr == INVALID_HANDLE)
        {
         Print("AlphaBot FIMATHE - ERRO: handle do ATR inválido (InpFimatheATRPeriod=",
               InpFimatheATRPeriod, ").");
         return(false);
        }

      if(Bars(_Symbol, PERIOD_CURRENT) < InpFimatheATRPeriod + 5)
         return(false);

      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(g_handle_atr, 0, 1, 1, atr) != 1)
        {
         Print("AlphaBot FIMATHE - ERRO: CopyBuffer(ATR) retornou ", GetLastError(), ".");
         return(false);
        }

      channelHeight = atr[0] * InpFimatheATRMult;
      if(channelHeight <= 0.0)
         return(false);

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 2, rates) != 2)
        {
         Print("AlphaBot FIMATHE - ERRO: CopyRates retornou ", GetLastError(), ".");
         return(false);
        }

      //--- Orientação sempre de ALTA (ZN abaixo do CR)
      crTopo    = rates[1].high;
      crBottom  = crTopo - channelHeight;
      canalAlta = true;
     }
   else
     {
      //--- AMPLITUDE VIA PERNADA/RECUO (PRICE ACTION)
      if(InpFimatheSwingBars < 2)
        {
         Print("AlphaBot FIMATHE - ERRO: InpFimatheSwingBars deve ser >= 2.");
         return(false);
        }

      if(Bars(_Symbol, PERIOD_CURRENT) < InpFimatheSwingBars + 2)
         return(false);

      //--- Maior máxima e menor mínima dos últimos N candles (exclui a vela atual)
      int shiftHigh = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, InpFimatheSwingBars, 1);
      int shiftLow  = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, InpFimatheSwingBars, 1);

      if(shiftHigh < 0 || shiftLow < 0)
        {
         Print("AlphaBot FIMATHE - ERRO: iHighest/iLowest retornaram ", GetLastError(), ".");
         return(false);
        }

      double highest = iHigh(_Symbol, PERIOD_CURRENT, shiftHigh);
      double lowest  = iLow(_Symbol, PERIOD_CURRENT, shiftLow);

      channelHeight = highest - lowest;
      if(channelHeight <= 0.0)
         return(false);

      //--- Tendência pela recência dos extremos: máxima mais recente => ALTA
      canalAlta = (shiftHigh <= shiftLow);

      crTopo   = highest;
      crBottom = lowest;
     }

//--- Fixação estática das bordas (CR e ZN contíguos, mesma altura)
   g_fimatheCRTop     = crTopo;
   g_fimatheCRBottom  = crBottom;
   g_fimatheCanalAlta = canalAlta;

   if(canalAlta)
     {
      //--- ALTA: ZN abaixo do CR (gatilho de venda abaixo do fundo da ZN)
      g_fimatheZNBottom = crBottom - channelHeight;
      g_fimatheZNTop    = 0.0;
     }
   else
     {
      //--- BAIXA: ZN acima do CR (gatilho de compra acima do topo da ZN)
      g_fimatheZNTop    = crTopo + channelHeight;
      g_fimatheZNBottom = 0.0;
     }

   g_fimatheChannelHeight   = channelHeight;
   g_fimatheCanaisDefinidos = true;

//--- Desenha as linhas exatamente nos valores estáticos
   DrawFimatheChannels(g_fimatheCRTop, g_fimatheCRBottom,
                       (canalAlta ? g_fimatheZNBottom : g_fimatheZNTop),
                       g_fimatheCanalAlta);

   Print("[FIMATHE] Canais FIXADOS [",
         (InpFimatheCalcType == FIMATHE_USE_ATR ? "ATR" : "SWING"),
         " | ", (canalAlta ? "ALTA" : "BAIXA"), "] -> CR Topo: ",
         DoubleToString(g_fimatheCRTop, _Digits),
         " | CR Fundo: ", DoubleToString(g_fimatheCRBottom, _Digits),
         " | ZN Externo: ",
         DoubleToString((canalAlta ? g_fimatheZNBottom : g_fimatheZNTop), _Digits),
         " | Altura: ", DoubleToString(channelHeight, _Digits), ".");
   return(true);
  }

//+------------------------------------------------------------------+
//| Limites do bloco CR+ZN (níveis efetivos de disparo).              |
//| COMPRA rompe acima do topo; VENDA rompe abaixo do fundo.          |
//+------------------------------------------------------------------+
double FimatheBandTop()
  {
   return(g_fimatheCanalAlta ? g_fimatheCRTop : g_fimatheZNTop);
  }

double FimatheBandBottom()
  {
   return(g_fimatheCanalAlta ? g_fimatheZNBottom : g_fimatheCRBottom);
  }

//+------------------------------------------------------------------+
//| Avalia o rompimento ESTRITO contra os canais estáticos.           |
//+------------------------------------------------------------------+
ENUM_ALPHA_SIGNAL CheckFimatheSignal()
  {
//--- Não abre novos setups enquanto existir posição ativa do robô
   if(ExistePosicaoRobo())
      return(SIGNAL_NONE);

//--- Fixa os canais apenas UMA vez por ciclo (mantém-se estáticos)
   if(!g_fimatheCanaisDefinidos)
     {
      if(!FimatheDefinirCanais())
         return(SIGNAL_NONE);
     }

//--- rates[0] = candle atual | rates[1] = candle de sinal | rates[2] = candle anterior
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 3, rates) != 3)
     {
      Print("AlphaBot FIMATHE - ERRO: CopyRates retornou ", GetLastError(), ".");
      return(SIGNAL_NONE);
     }

   double fechamentoAtual     = rates[1].close; // fechamento do candle de sinal
   double fechamentoAnterior  = rates[2].close; // fechamento do candle anterior

//--- Limites efetivos do bloco CR+ZN (dependem da orientação/tendência)
   double bandTop    = FimatheBandTop();
   double bandBottom = FimatheBandBottom();

//--- ZONA NEUTRA: proibido negociar dentro da faixa [BandBottom ; BandTop]
   if(fechamentoAtual >= bandBottom && fechamentoAtual <= bandTop)
     {
      if(rates[0].time != g_fimatheUltimaBarraLog)
        {
         g_fimatheUltimaBarraLog = rates[0].time;
         Print("[FIMATHE AGUARDANDO] CR Topo: ",
               DoubleToString(g_fimatheCRTop, _Digits),
               " | ZN Fundo: ", DoubleToString(g_fimatheZNBottom, _Digits),
               " | Preço Atual: ", DoubleToString(fechamentoAtual, _Digits),
               " | Status: Fora de zona de disparo");
        }
      return(SIGNAL_NONE);
     }

//--- Gatilho de COMPRA: rompimento estritamente acima do topo do bloco,
//--- vindo de dentro/abaixo do canal (candle anterior dentro do bloco)
   if(fechamentoAtual > bandTop && fechamentoAnterior <= bandTop)
     {
      g_signalPadrao = "Fimathe (Rompimento Superior)";
      Print("SINAL DE COMPRA VALIDADO [FIMATHE]: Fechamento (",
            DoubleToString(fechamentoAtual, _Digits), ") > Topo do Canal (",
            DoubleToString(bandTop, _Digits), ") | Anterior (",
            DoubleToString(fechamentoAnterior, _Digits), ") <= Topo.");
      return(SIGNAL_BUY);
     }

//--- Gatilho de VENDA: rompimento estritamente abaixo do fundo do bloco,
//--- vindo de dentro/acima do canal (candle anterior dentro do bloco)
   if(fechamentoAtual < bandBottom && fechamentoAnterior >= bandBottom)
     {
      g_signalPadrao = "Fimathe (Rompimento Inferior)";
      Print("SINAL DE VENDA VALIDADO [FIMATHE]: Fechamento (",
            DoubleToString(fechamentoAtual, _Digits), ") < Fundo do Canal (",
            DoubleToString(bandBottom, _Digits), ") | Anterior (",
            DoubleToString(fechamentoAnterior, _Digits), ") >= Fundo.");
      return(SIGNAL_SELL);
     }

   return(SIGNAL_NONE);
  }

//+==================================================================+
//|      MOTOR ARMADILHA DE LIQUIDEZ / WYCKOFF (FAKE BREAKOUT)        |
//|                                                                    |
//| Detecta armadilhas de liquidez no fechamento da vela 1:            |
//|   COMPRA (Spring / Bear Trap): a mínima fura o suporte e o         |
//|   fechamento volta para cima, com volume de absorção acima da      |
//|   média (Wyckoff).                                                 |
//|   VENDA  (Upthrust / Bull Trap): a máxima fura a resistência e o   |
//|   fechamento volta para baixo, com volume acima da média.          |
//+==================================================================+

//+------------------------------------------------------------------+
//| Tamanho de 1 pip conforme os dígitos do símbolo.                  |
//+------------------------------------------------------------------+
double TrapPipSize()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return(10.0 * _Point);
   return(_Point);
  }

//+------------------------------------------------------------------+
//| Avalia a armadilha de liquidez no fechamento da vela 1.           |
//+------------------------------------------------------------------+
ENUM_ALPHA_SIGNAL CheckTrapSignal()
  {
   if(InpTrapLookback < 2 || InpTrapVolMAPeriod < 2)
      return(SIGNAL_NONE);

//--- Avalia apenas UMA vez por candle fechado (evita reavaliação por tick)
   datetime barraSinal = iTime(_Symbol, PERIOD_CURRENT, 1);
   if(barraSinal == 0 || barraSinal == g_trapUltimaBarraAvaliada)
      return(SIGNAL_NONE);
   g_trapUltimaBarraAvaliada = barraSinal;

//--- Barras suficientes para suporte/resistência + média de volume
   if(Bars(_Symbol, PERIOD_CURRENT) < InpTrapLookback + InpTrapVolMAPeriod + 3)
      return(SIGNAL_NONE);

//--- A) Níveis de liquidez: menor mínima e maior máxima (i = 2 .. 1 + lookback)
   int shiftHigh = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, InpTrapLookback, 2);
   int shiftLow  = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, InpTrapLookback, 2);
   if(shiftHigh < 0 || shiftLow < 0)
      return(SIGNAL_NONE);

   double resistanceLevel = iHigh(_Symbol, PERIOD_CURRENT, shiftHigh);
   double supportLevel    = iLow(_Symbol, PERIOD_CURRENT, shiftLow);

//--- B) Média móvel simples do volume (i = 2 .. 1 + InpTrapVolMAPeriod)
   double volSum = 0.0;
   for(int i = 2; i <= 1 + InpTrapVolMAPeriod; i++)
      volSum += (double)iVolume(_Symbol, PERIOD_CURRENT, i);

   double volMA = volSum / (double)InpTrapVolMAPeriod;
   if(volMA <= 0.0)
      return(SIGNAL_NONE);

   double vol1 = (double)iVolume(_Symbol, PERIOD_CURRENT, 1);
   bool   isHighVolume = (vol1 >= volMA * InpTrapVolMultiplier);

//--- Dados da vela de sinal
   double low1   = iLow(_Symbol, PERIOD_CURRENT, 1);
   double high1  = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);

   double pip    = TrapPipSize();
   double buffer = InpTrapStopBufferPips * pip;

//--- C) COMPRA (Spring / Bear Trap): fura o suporte, fecha acima, com volume
   if(low1 < supportLevel && close1 > supportLevel && isHighVolume)
     {
      g_trapAtivo    = true;
      g_trapStopLoss = low1 - buffer;
      g_signalPadrao = "Armadilha (Spring / Bear Trap)";

      Print("SINAL DE COMPRA VALIDADO [ARMADILHA]: Mínima (",
            DoubleToString(low1, _Digits), ") < Suporte (",
            DoubleToString(supportLevel, _Digits), ") | Fechamento (",
            DoubleToString(close1, _Digits), ") > Suporte | Volume ",
            DoubleToString(vol1, 0), " >= ", DoubleToString(volMA * InpTrapVolMultiplier, 0),
            " | SL=", DoubleToString(g_trapStopLoss, _Digits), ".");
      return(SIGNAL_BUY);
     }

//--- D) VENDA (Upthrust / Bull Trap): fura a resistência, fecha abaixo, com volume
   if(high1 > resistanceLevel && close1 < resistanceLevel && isHighVolume)
     {
      g_trapAtivo    = true;
      g_trapStopLoss = high1 + buffer;
      g_signalPadrao = "Armadilha (Upthrust / Bull Trap)";

      Print("SINAL DE VENDA VALIDADO [ARMADILHA]: Máxima (",
            DoubleToString(high1, _Digits), ") > Resistência (",
            DoubleToString(resistanceLevel, _Digits), ") | Fechamento (",
            DoubleToString(close1, _Digits), ") < Resistência | Volume ",
            DoubleToString(vol1, 0), " >= ", DoubleToString(volMA * InpTrapVolMultiplier, 0),
            " | SL=", DoubleToString(g_trapStopLoss, _Digits), ".");
      return(SIGNAL_SELL);
     }

   return(SIGNAL_NONE);
  }

//+------------------------------------------------------------------+
//| FUNÇÃO CENTRALIZADORA DE SINAIS DE ENTRADA                        |
//| Encaminha para o motor escolhido no painel de inputs:             |
//|   SIGNAL_CANDLE_PATTERNS -> Padrões de Candle (Engolfo/Martelo)   |
//|   SIGNAL_FIMATHE         -> Metodologia Fimathe (CR + ZN)         |
//|   SIGNAL_TRAP            -> Armadilha de Liquidez / Wyckoff       |
//+------------------------------------------------------------------+
ENUM_ALPHA_SIGNAL CheckEntrySignal()
  {
   if(InpEntrySignalType == SIGNAL_FIMATHE)
      return(CheckFimatheSignal());

   if(InpEntrySignalType == SIGNAL_TRAP)
      return(CheckTrapSignal());

   return(CheckPriceActionSignal());
  }

//+------------------------------------------------------------------+
//| Reinicia o estado do Motor Fimathe (subciclo/Breakeven).          |
//+------------------------------------------------------------------+
void ResetFimatheState()
  {
   g_entradaFimathe       = false;
   g_fimatheBEFeito       = false;
   g_fimatheAnchorTicket  = 0;
   g_fimatheChannelHeight = 0.0;
  }

//+------------------------------------------------------------------+
//| Localiza o ticket da posição-âncora deste robô numa direção.      |
//+------------------------------------------------------------------+
ulong FimatheTicketAncora(const int direcao)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE tipo = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((direcao == 1 && tipo == POSITION_TYPE_BUY) ||
         (direcao == -1 && tipo == POSITION_TYPE_SELL))
         return(ticket);
     }

   return(0);
  }

//+------------------------------------------------------------------+
//| SUBCICLO DE PROTEÇÃO FIMATHE (Breakeven no 1º Canal)              |
//| Enquanto a posição-âncora da Fimathe estiver aberta, monitora o   |
//| lucro flutuante. Ao percorrer 1 canal (ChannelHeight) a favor,    |
//| move o Stop Loss para o preço exato de entrada (0x0/Breakeven).   |
//+------------------------------------------------------------------+
void ManageFimatheSubcycle()
  {
   if(!InpUseSubcycleProtect || !g_entradaFimathe || g_fimatheBEFeito)
      return;

   if(g_fimatheAnchorTicket == 0)
      return;

//--- A âncora já não existe mais: encerra o monitoramento do subciclo
   if(!PositionSelectByTicket(g_fimatheAnchorTicket))
     {
      ResetFimatheState();
      return;
     }

   ENUM_POSITION_TYPE tipo = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double precoEntrada = PositionGetDouble(POSITION_PRICE_OPEN);
   double precoAtual   = (tipo == POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(precoAtual <= 0.0 || precoEntrada <= 0.0 || g_fimatheChannelHeight <= 0.0)
      return;

//--- Distância percorrida a favor da operação
   double distanciaFavor = (tipo == POSITION_TYPE_BUY)
                           ? (precoAtual - precoEntrada)
                           : (precoEntrada - precoAtual);

//--- Ainda não completou 1 canal a favor
   if(distanciaFavor < g_fimatheChannelHeight)
      return;

   double slAtual = PositionGetDouble(POSITION_SL);
   double novoSL  = NormalizeDouble(precoEntrada, _Digits);

//--- Já está em Breakeven (ou melhor): nada a fazer
   if(tipo == POSITION_TYPE_BUY && slAtual != 0.0 && slAtual >= novoSL)
     {
      g_fimatheBEFeito = true;
      return;
     }

   if(tipo == POSITION_TYPE_SELL && slAtual != 0.0 && slAtual <= novoSL)
     {
      g_fimatheBEFeito = true;
      return;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   double tp = PositionGetDouble(POSITION_TP);

   if(trade.PositionModify(g_fimatheAnchorTicket, novoSL, tp))
     {
      g_fimatheBEFeito = true;
      Print("[FIMATHE] Subciclo de 1 Canal atingido. Posição movida para Breakeven");
     }
   else
     {
      Print("[FIMATHE] ERRO ao mover a posição-âncora para Breakeven | ticket=",
            g_fimatheAnchorTicket, " | retcode=", trade.ResultRetcode(),
            " (", trade.ResultRetcodeDescription(), ").");
     }
  }

//+------------------------------------------------------------------+
//| REVERSÃO FIMATHE (VIRAR A MÃO)                                    |
//| Com posição aberta, monitora o rompimento da ZN (contra COMPRA)   |
//| ou do CR (contra VENDA). Se a reversão estiver habilitada, encerra|
//| o ciclo e abre a posição oposta; caso contrário, apenas encerra.  |
//+------------------------------------------------------------------+
void ManageFimatheReversal()
  {
   if(InpEntrySignalType != SIGNAL_FIMATHE)
      return;

//--- O Grid Bidirecional gerencia as pernas por conta própria
   if(InpBidirectionalGrid)
      return;

//--- Direção da posição ativa do ciclo (âncora/grade)
   int direcao = 0;
   if(InpEnableGL && g_glGrid.ativo)
      direcao = g_glGrid.direcao;
   else
      direcao = GetOpenPositionDirection();

   if(direcao == 0)
      return;

//--- Sem canais de referência fixados não há como avaliar o rompimento
   double bandTop    = FimatheBandTop();
   double bandBottom = FimatheBandBottom();
   if(bandTop <= 0.0 || bandBottom <= 0.0 || bandTop <= bandBottom)
      return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 2, rates) != 2)
      return;

   double fechamento = rates[1].close;

//--- Rompimento contra a COMPRA: fechou estritamente abaixo do fundo do bloco
   bool reversaoCompra = (direcao == 1  && fechamento < bandBottom);
//--- Rompimento contra a VENDA: fechou estritamente acima do topo do bloco
   bool reversaoVenda  = (direcao == -1 && fechamento > bandTop);

   if(!reversaoCompra && !reversaoVenda)
      return;

//--- Reversão desativada: encerra a posição e limpa os canais
   if(!InpAllowFimatheReversal)
     {
      if(InpEnableGL)
         CloseLegPositions(g_glGrid, "Fimathe - Rompimento contra a posição");
      else
        {
         ulong ticketFechado = 0;
         CloseOpenPosition(ticketFechado);
        }

      ResetFimatheState();
      ClearFimatheChannels();

      Print("[FIMATHE] Rompimento contra a posição (reversão desativada). ",
            "Posição encerrada e canais removidos. Aguardando novo sinal neutro.");
      return;
     }

//--- Reversão habilitada: encerra TODO o ciclo na direção atual
   if(InpEnableGL)
      CloseLegPositions(g_glGrid, "Fimathe Reversal (Virada de Mão)");
   else
     {
      ulong ticketFechado = 0;
      CloseOpenPosition(ticketFechado);
     }

   ResetFimatheState();

//--- Abre a posição oposta (Virada de Mão)
   if(reversaoCompra)
      ExecuteSell();
   else
      ExecuteBuy();

//--- Recalcula e redesenha os canais ajustados ao novo sentido
   g_fimatheCanaisDefinidos = false;
   ClearFimatheChannels();
   FimatheDefinirCanais();

   if(reversaoCompra)
      Print("[FIMATHE REVERSAL] Rompimento confirmado da ZN. ",
            "Compra encerrada e Venda aberta (Virada de Mão)");
   else
      Print("[FIMATHE REVERSAL] Rompimento confirmado do CR. ",
            "Venda encerrada e Compra aberta (Virada de Mão)");
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
   ArrayResize(st.nivelPositivo, 0);
   ArrayResize(st.nivelParcial, 0);
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
   ArrayResize(st.nivelPositivo, totalNiveis);
   ArrayResize(st.nivelParcial, totalNiveis);

   for(int i = 0; i < totalNiveis; i++)
     {
      st.nivelAberto[i]   = false;
      st.nivelTicket[i]   = 0;
      st.nivelPositivo[i] = false;
      st.nivelParcial[i]  = false;
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
         st.nivelAberto[i]   = false;
         st.nivelTicket[i]   = 0;
         st.nivelPositivo[i] = false;
         st.nivelParcial[i]  = false;
        }
     }
  }

//+------------------------------------------------------------------+
//| Abre uma sub-operação a mercado no nível informado.               |
//| Gradiente Negativo (drawdown): lote padrão, TP no nível k+1 e SL  |
//| global (comportamento original).                                  |
//| Gradiente Positivo (piramidagem): lote base, SL nativo 1 nível    |
//| atrás e SEM TP nativo (alvo gerido virtualmente).                 |
//+------------------------------------------------------------------+
bool GL_OpenPosition(CGLGrid &st, const int offset, const bool positivo = false)
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

   bool   piramidar = (positivo && InpEnablePositivePyramid);
   double tp   = 0.0;
   double sl   = 0.0;
   double lote = 0.0;

   if(piramidar)
     {
      //--- GRADIENTE POSITIVO: lote base, SL nativo 1 nível atrás, SEM TP nativo
      tp   = 0.0;
      sl   = NormalizeDouble(GL_PrecoDoNivel(st, offset - 1), _Digits);
      lote = GL_NormalizarLote(InpPositiveLotBase);
     }
   else
     {
      //--- GRADIENTE NEGATIVO (drawdown): comportamento original
      tp   = NormalizeDouble(GL_PrecoDoNivel(st, offsetAlvo), _Digits);
      sl   = NormalizeDouble(st.globalSL, _Digits);
      lote = GL_NormalizarLote(InpLoteInicial);
     }

   if(lote <= 0.0)
     {
      Print("AlphaBot GL - ERRO: lote inválido para o símbolo ", _Symbol, ".");
      return(false);
     }

   string comentario = "GL " + (st.direcao == 1 ? "BUY" : "SELL") +
                       " Nivel " + IntegerToString(offset) +
                       (piramidar ? " Piramide" : "");

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

      st.nivelAberto[idx]   = true;
      st.nivelTicket[idx]   = ticket;
      st.nivelPositivo[idx] = piramidar;
      st.nivelParcial[idx]  = false;

      Print("AlphaBot GL - Sub-operação aberta no nível ", offset,
            " (", (st.direcao == 1 ? "COMPRA" : "VENDA"), ")",
            (piramidar ? " [GRADIENTE POSITIVO]" : " [GRADIENTE NEGATIVO]"),
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
      st.nivelAberto[idx]   = false;
      st.nivelTicket[idx]   = 0;
      st.nivelPositivo[idx] = false;
      st.nivelParcial[idx]  = false;
      return;
     }

   if(trade.PositionClose(ticket))
      Print("AlphaBot GL - Nível ", offset, " encerrado no lucro (",
            motivo, ") | ticket=", ticket, ".");
   else
      Print("AlphaBot GL - ERRO ao encerrar nível ", offset, " | ticket=", ticket,
            ". Retcode=", trade.ResultRetcode(),
            " (", trade.ResultRetcodeDescription(), ").");

   st.nivelAberto[idx]   = false;
   st.nivelTicket[idx]   = 0;
   st.nivelPositivo[idx] = false;
   st.nivelParcial[idx]  = false;
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
//| Gradiente Negativo: ao atingir o nível k, fecha a posição de k-1  |
//| e engatilha nova posição em k, com TP no nível k+1 (rolagem).     |
//| Gradiente Positivo (piramidagem): NÃO fecha os runners positivos  |
//| já abertos e engatilha uma nova reentrada no nível alcançado.     |
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

   if(InpEnablePositivePyramid)
     {
      //--- GRADIENTE POSITIVO: preserva os runners (não os fecha na rolagem)
      for(int offset = nivelMax - 1; offset >= -InpLevelsSL; offset--)
        {
         int idx = GL_IndiceDoNivel(offset);
         if(idx < 0 || idx >= ArraySize(st.nivelAberto) || !st.nivelAberto[idx])
            continue;

         if(st.nivelPositivo[idx])
            continue; // runner do gradiente positivo segue vivo, protegido pelo SL nativo

         GL_ClosePositionAt(st, offset,
                            "rolagem para o nível " + IntegerToString(nivelMax));
        }

      //--- Nova reentrada de piramidagem no nível alcançado (alvo virtual em k+1)
      GL_OpenPosition(st, nivelMax, true);
      return;
     }

//--- Gradiente Negativo: rolagem original
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
//| FECHAMENTO PARCIAL VIRTUAL DO GRADIENTE POSITIVO                  |
//| Monitora cada reentrada positiva: ao atingir o nível alvo (1 nível |
//| à frente da entrada), fecha parcialmente o volume base via TP      |
//| virtual, deixando o "runner" remanescente protegido pelo SL nativo |
//| já enviado na abertura. Só age sobre posições do Gradiente         |
//| Positivo; o Gradiente Negativo permanece intocado.                 |
//+------------------------------------------------------------------+
void GL_ManagePositivePartials(CGLGrid &st, const double curM)
  {
   if(!InpEnablePositivePyramid)
      return;

   int total = ArraySize(st.nivelAberto);

   for(int idx = 0; idx < total; idx++)
     {
      if(!st.nivelAberto[idx] || !st.nivelPositivo[idx] || st.nivelParcial[idx])
         continue;

      int offset     = idx - InpLevelsSL;
      int offsetAlvo = offset + 1;

      if(offsetAlvo > InpLevelsTP)
         continue;

//--- Alvo virtual: 1 nível à frente do preço de entrada da reentrada
      double metricaAlvo = GL_MetricaDoNivel(st, offsetAlvo);
      if(curM < metricaAlvo)
         continue;

      ulong ticket = st.nivelTicket[idx];
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);

//--- Só faz a parcial se o volume ainda for o lote base cheio (ainda não parciou)
      if(MathAbs(volume - InpPositiveLotBase) > 0.0000001)
        {
         st.nivelParcial[idx] = true;
         continue;
        }

      if(InpPartialCloseVolume <= 0.0 || InpPartialCloseVolume >= volume)
        {
         Print("[GRID POSITIVO] AVISO: volume de parcial inválido (",
               DoubleToString(InpPartialCloseVolume, 2),
               ") para o ticket ", ticket, " com volume ",
               DoubleToString(volume, 2), ". Parcial ignorada.");
         st.nivelParcial[idx] = true;
         continue;
        }

      if(trade.PositionClosePartial(ticket, InpPartialCloseVolume))
        {
         st.nivelParcial[idx] = true;
         Print("[GRID POSITIVO] Parcial executada no ticket ", ticket,
               ". Runner protegido no SL nativo");
        }
      else
        {
         Print("[GRID POSITIVO] ERRO na parcial do ticket ", ticket,
               ". Retcode=", trade.ResultRetcode(),
               " (", trade.ResultRetcodeDescription(), ").");
        }
     }
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
   ResetFimatheState();
   ClearFimatheChannels();
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

//--- Fechamento parcial virtual (Virtual TP) exclusivo do Gradiente Positivo
   GL_ManagePositivePartials(st, curM);

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
//| Limpeza automática das linhas Fimathe quando o ciclo termina:     |
//| se não restar NENHUMA posição do robô (TP/SL/fecho da cesta), as  |
//| linhas são removidas do gráfico para evitar poluição visual.      |
//+------------------------------------------------------------------+
void CheckFimatheGraphicsCleanup()
  {
   bool temPosicao = ExistePosicaoRobo();

//--- Registra que o ciclo teve posição ativa
   if(temPosicao)
     {
      g_fimatheTinhaPosicao = true;
      return;
     }

//--- Sem posições: só limpa na TRANSIÇÃO "tinha posição" -> "sem posição".
//--- Isto evita apagar/redesenhar os canais ESTÁTICOS a cada tick enquanto
//--- o motor apenas aguarda um novo rompimento.
   if(!g_fimatheTinhaPosicao)
      return;

   g_fimatheTinhaPosicao = false;

   if(!g_fimatheGraficoAtivo)
     {
      g_fimatheCanaisDefinidos = false;
      return;
     }

   ClearFimatheChannels();
   Print("[FIMATHE GRAPHICS] Ciclo encerrado (sem posições do robô). ",
         "Canais removidos do gráfico.");
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
   double sl = 0.0;
   double tp = 0.0;

//--- SL/TP específicos da Armadilha de Liquidez (baseados no pavio + R:R)
   if(g_trapAtivo)
     {
      sl = NormalizeDouble(g_trapStopLoss, _Digits);
      double risco = precoEntrada - sl;
      if(risco <= 0.0)
        {
         Print("AlphaBot - ERRO [ARMADILHA]: distância de risco inválida para COMPRA (SL=",
               DoubleToString(sl, _Digits), " | Ask=",
               DoubleToString(precoEntrada, _Digits), "). Ordem abortada.");
         g_trapAtivo = false;
         return;
        }
      tp = NormalizeDouble(precoEntrada + risco * InpTrapRiskReward, _Digits);
     }
   else
     {
      sl = NormalizeDouble(precoEntrada - (InpStopLossGlobal * _Point), _Digits);
      tp = NormalizeDouble(precoEntrada + (InpTakeProfitGlobal * _Point), _Digits);
     }

   if(trade.Buy(InpLoteInicial, _Symbol, precoEntrada, sl, tp, "AlphaBot Compra"))
     {
      Print("=== ALPHABOT: ORDEM DE COMPRA EXECUTADA ===");
      Print("SINAL DE COMPRA: ", g_signalPadrao, " detectado no candle [1]");
      Print("Preço de Entrada: ", DoubleToString(trade.ResultPrice(), _Digits),
            " | SL: ", DoubleToString(sl, _Digits),
            " | TP: ", DoubleToString(tp, _Digits));
      Print("AlphaBot - Ticket: ", trade.ResultOrder(), ".");

      if(InpEntrySignalType == SIGNAL_FIMATHE)
        {
         g_entradaFimathe      = true;
         g_fimatheBEFeito      = false;
         g_fimatheAnchorTicket = FimatheTicketAncora(1);
         g_fimatheCanaisDefinidos = false; // canais consumidos pelo rompimento
         Print("[FIMATHE] Entrada de COMPRA registrada. Subciclo de 1 Canal ",
               (InpUseSubcycleProtect ? "ATIVO" : "INATIVO"),
               " | âncora=", g_fimatheAnchorTicket, ".");
        }
      else
         ResetFimatheState();

      if(InpEnableGL)
         CalculateGLLevels(g_glGrid, trade.ResultPrice(), 1);
     }
   else
     {
      Print("AlphaBot - ERRO ao enviar ordem de COMPRA. Retcode: ",
            trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(),
            ") | Erro: ", GetLastError());
     }

//--- Consome o sinal da Armadilha (usado apenas uma vez)
   g_trapAtivo = false;
  }

//+------------------------------------------------------------------+
//| Executa ordem de VENDA (Martelo Invertido / Engolfo de Baixa).   |
//+------------------------------------------------------------------+
void ExecuteSell()
  {
   double precoEntrada = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0.0;
   double tp = 0.0;

//--- SL/TP específicos da Armadilha de Liquidez (baseados no pavio + R:R)
   if(g_trapAtivo)
     {
      sl = NormalizeDouble(g_trapStopLoss, _Digits);
      double risco = sl - precoEntrada;
      if(risco <= 0.0)
        {
         Print("AlphaBot - ERRO [ARMADILHA]: distância de risco inválida para VENDA (SL=",
               DoubleToString(sl, _Digits), " | Bid=",
               DoubleToString(precoEntrada, _Digits), "). Ordem abortada.");
         g_trapAtivo = false;
         return;
        }
      tp = NormalizeDouble(precoEntrada - risco * InpTrapRiskReward, _Digits);
     }
   else
     {
      sl = NormalizeDouble(precoEntrada + (InpStopLossGlobal * _Point), _Digits);
      tp = NormalizeDouble(precoEntrada - (InpTakeProfitGlobal * _Point), _Digits);
     }

   if(trade.Sell(InpLoteInicial, _Symbol, precoEntrada, sl, tp, "AlphaBot Venda"))
     {
      Print("=== ALPHABOT: ORDEM DE VENDA EXECUTADA ===");
      Print("SINAL DE VENDA: ", g_signalPadrao, " detectado no candle [1]");
      Print("Preço de Entrada: ", DoubleToString(trade.ResultPrice(), _Digits),
            " | SL: ", DoubleToString(sl, _Digits),
            " | TP: ", DoubleToString(tp, _Digits));
      Print("AlphaBot - Ticket: ", trade.ResultOrder(), ".");

      if(InpEntrySignalType == SIGNAL_FIMATHE)
        {
         g_entradaFimathe      = true;
         g_fimatheBEFeito      = false;
         g_fimatheAnchorTicket = FimatheTicketAncora(-1);
         g_fimatheCanaisDefinidos = false; // canais consumidos pelo rompimento
         Print("[FIMATHE] Entrada de VENDA registrada. Subciclo de 1 Canal ",
               (InpUseSubcycleProtect ? "ATIVO" : "INATIVO"),
               " | âncora=", g_fimatheAnchorTicket, ".");
        }
      else
         ResetFimatheState();

      if(InpEnableGL)
         CalculateGLLevels(g_glGrid, trade.ResultPrice(), -1);
     }
   else
     {
      Print("AlphaBot - ERRO ao enviar ordem de VENDA. Retcode: ",
            trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(),
            ") | Erro: ", GetLastError());
     }

//--- Consome o sinal da Armadilha (usado apenas uma vez)
   g_trapAtivo = false;
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
//--- Subciclo de proteção Fimathe (Breakeven no 1º Canal) da posição-âncora
   ManageFimatheSubcycle();

//--- Reversão Fimathe (Virar a Mão) ao romper a ZN/CR contra a posição
   ManageFimatheReversal();

//--- Remove as linhas do Fimathe quando o ciclo é encerrado (TP/SL/cesta)
   CheckFimatheGraphicsCleanup();

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

//--- Motor de sinal de entrada selecionado no painel de inputs
//--- (Padrões de Candle OU Metodologia Fimathe)
   ENUM_ALPHA_SIGNAL sinal=CheckEntrySignal();

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

   ResetFimatheState();

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
