import os
from pathlib import Path

import MetaTrader5 as mt5
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent
ENV_PATH = BASE_DIR / ".env"

MARGIN_MODE_NAMES = {
    mt5.ACCOUNT_MARGIN_MODE_RETAIL_NETTING: "NETTING",
    mt5.ACCOUNT_MARGIN_MODE_EXCHANGE: "EXCHANGE",
    mt5.ACCOUNT_MARGIN_MODE_RETAIL_HEDGING: "HEDGE",
}


def main() -> None:
    load_dotenv(ENV_PATH)

    login = os.getenv("MT5_LOGIN", "").strip()
    password = os.getenv("MT5_PASSWORD", "").strip()
    server = os.getenv("MT5_SERVER", "").strip()

    placeholders = {"SUA_CONTA_AQUI", "SUA_SENHA_AQUI", "SEU_SERVIDOR_AQUI"}
    has_real_credentials = login.isdigit() and password and server and login not in placeholders

    try:
        if has_real_credentials:
            print(f"Autenticando no servidor '{server}' com a conta {login} ...")
            connected = mt5.initialize(login=int(login), password=password, server=server)
        else:
            print("ATENÇÃO: o .env ainda contém credenciais de exemplo.")
            print("Conectando ao terminal MT5 com a sessão já autenticada ...")
            connected = mt5.initialize()

        if not connected:
            print(f"FALHA na inicialização do MT5: {mt5.last_error()}")
            print("Certifique-se de que o terminal MetaTrader 5 está aberto e autenticado.")
            return

        print(f"Biblioteca MetaTrader5 v{mt5.__version__} conectada ao terminal.")

        account = mt5.account_info()
        if account is None:
            print(f"ERRO: não foi possível obter os dados da conta: {mt5.last_error()}")
            print("Preencha as credenciais reais no arquivo .env e execute novamente.")
            return

        margin_mode = account.margin_mode

        print(f"Corretora        : {account.company}")
        print(f"Número da conta  : {account.login}")
        print(f"Saldo            : {account.balance:.2f}")
        print(f"Tipo da conta    : {MARGIN_MODE_NAMES.get(margin_mode, margin_mode)}")

        if margin_mode != mt5.ACCOUNT_MARGIN_MODE_RETAIL_HEDGING:
            print()
            print("ALERTA: a conta conectada NÃO é do tipo HEDGE.")
            print("O robô requere uma conta com ACCOUNT_MARGIN_MODE_RETAIL_HEDGING.")
            print("Execute com uma conta HEDGE antes de operar.")
            return

        print()
        print("OK: conta do tipo HEDGE confirmada. Robô pronto para operar.")

    finally:
        mt5.shutdown()
        print("Conexão com o MetaTrader 5 finalizada.")


if __name__ == "__main__":
    main()