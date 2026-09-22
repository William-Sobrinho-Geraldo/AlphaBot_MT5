//+------------------------------------------------------------------+
//|                                              AlphaBot_MT5.mq5     |
//|                                                AlphaBot Trading  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "AlphaBot Trading"
#property link      "https://www.mql5.com"
#property version   "1.00"

//+------------------------------------------------------------------+
//| Parâmetros Operacionais - Interface nativa do MT5                |
//+------------------------------------------------------------------+
input group "=== AlphaBot - Parâmetros Operacionais ==="
input double InpLoteInicial     = 0.01; // Lote Inicial
input int    InpPassoGridPontos = 200;  // Passo do Grid (pontos)
input int    InpStopLossGlobal  = 300;  // Stop Loss Global (pontos)

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

   Print("AlphaBot - Inicializado com sucesso: conta em modo HEDGE.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Print("AlphaBot - Desinicializado. Código de motivo: ", reason);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- Lógica operacional (Gradiente Linear Duplo, Filtros SMA/ADX,
//---     Offsetting e verificação de HEDGE) será implementada aqui.
  }
//+------------------------------------------------------------------+