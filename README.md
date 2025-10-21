# KipuBankV2

Un contrato inteligente avanzado que implementa un sistema de bóvedas multi-token con control de acceso, límites dinámicos basados en USD (via Chainlink), y contabilidad unificada.

## Descripción

KipuBankV2 es la evolución del contrato original KipuBank, desarrollado para el Trabajo Final del Módulo 3. Esta versión incorpora funcionalidades avanzadas de Solidity y patrones de seguridad de nivel producción.

### Nuevas Características V2

- **Multi-Token Support**: Depósitos y retiros de ETH y tokens ERC-20
- **Control de Acceso por Roles**: Administración mediante OpenZeppelin AccessControl
- **Límites Dinámicos en USD**: Conversión ETH/USD usando Chainlink Data Feeds
- **Contabilidad Unificada**: Sistema normalizado a 6 decimales (USDC standard)
- **Conversión de Decimales**: Manejo automático de diferentes precisiones de tokens
- **Seguridad Reforzada**: ReentrancyGuard y validaciones exhaustivas

## Arquitectura Mejorada

### Nuevos Componentes

#### Control de Acceso
```solidity
bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
```
- Role-based access control usando OpenZeppelin
- Funciones administrativas protegidas
- Gestión segura de configuración del banco

#### Declaración de Tipos
```solidity
struct TokenBalance {
    uint256 nativeBalance;
    mapping(address => uint256) erc20Balances;
}
```

#### Oráculo Chainlink
```solidity
AggregatorV3Interface internal immutable i_priceFeed;
```
- Conversión ETH/USD en tiempo real
- Límite del banco expresado en USD
- Verificación de precios actualizados

#### Variables Constant
```solidity
uint8 private constant INTERNAL_DECIMALS = 6;
address private constant NATIVE_TOKEN = address(0);
```

#### Mappings Anidados
```solidity
mapping(address => mapping(address => uint256)) private s_vaults;
// s_vaults[usuario][token] = balance
```

### Funciones Principales V2

#### Depósitos
- `depositNative()`: Depositar ETH (payable)
- `depositERC20(address token, uint256 amount)`: Depositar tokens ERC-20

#### Retiros
- `withdrawNative(uint256 amount)`: Retirar ETH
- `withdrawERC20(address token, uint256 amount)`: Retirar tokens ERC-20

#### Administración (Solo ADMIN_ROLE)
- `updateWithdrawalLimit(uint256 newLimit)`: Actualizar límite de retiro
- `updateBankCapUSD(uint256 newCapUSD)`: Actualizar capacidad en USD
- `pauseDeposits()` / `unpauseDeposits()`: Control de emergencia

#### Consultas
- `getVaultBalance(address user, address token)`: Balance de usuario por token
- `getTotalDepositsUSD()`: Total depositado en USD
- `getETHPriceUSD()`: Precio actual ETH/USD del oráculo
- `convertToInternalDecimals(uint256 amount, uint8 tokenDecimals)`: Conversión de decimales

### Conversión de Decimales

El contrato normaliza todos los valores a 6 decimales (estándar USDC) para contabilidad interna:

```solidity
function convertToInternalDecimals(
    uint256 amount, 
    uint8 tokenDecimals
) public pure returns (uint256) {
    if (tokenDecimals > INTERNAL_DECIMALS) {
        return amount / (10 ** (tokenDecimals - INTERNAL_DECIMALS));
    } else if (tokenDecimals < INTERNAL_DECIMALS) {
        return amount * (10 ** (INTERNAL_DECIMALS - tokenDecimals));
    }
    return amount;
}
```

**Ejemplo:**
- ETH (18 decimals): 1 ETH = 1000000000000000000 → normalizado a 1000000 (6 decimals)
- USDC (6 decimals): 100 USDC = 100000000 → sin cambios
- USDT (6 decimals): 50 USDT = 50000000 → sin cambios

### Eventos V2

```solidity
event NativeDeposit(address indexed user, uint256 amount, uint256 newBalance);
event ERC20Deposit(address indexed user, address indexed token, uint256 amount);
event NativeWithdrawal(address indexed user, uint256 amount, uint256 newBalance);
event ERC20Withdrawal(address indexed user, address indexed token, uint256 amount);
event WithdrawalLimitUpdated(uint256 oldLimit, uint256 newLimit);
event BankCapUSDUpdated(uint256 oldCap, uint256 newCap);
```

### Errores Personalizados V2

```solidity
error UnauthorizedAccess();
error UnsupportedToken();
error BankCapacityExceededUSD();
error StalePrice();
error InvalidPriceData();
error DepositsArePaused();
```

## 🚀 Instrucciones de Despliegue

### Prerrequisitos
- MetaMask con Sepolia ETH
- Etherscan API Key (para verificación)

### Deploy con Remix

1. **Abrir Remix IDE**: https://remix.ethereum.org
2. **Importar el contrato**: Copia `KipuBankV2.sol` en Remix
3. **Compilar**: 
   - Solidity version: `0.8.26`
   - Optimization: Enabled (200 runs)
4. **Desplegar**:
   - Environment: "Injected Provider - MetaMask"
   - Red: Sepolia
   - Contrato: `KipuBankV2`
   - Constructor args:
     - `_withdrawalLimitUSD`: `1000000000` (1,000 USD)
     - `_bankCapUSD`: `100000000000` (100,000 USD)
     - `_ethPriceFeed`: `0x694AA1769357215DE4FAC081bf1f309aDC325306`
   - Click "Deploy" y confirmar en MetaMask

### Verificación en Etherscan

Para verificar el contrato desplegado, tuve que aplanarlo debido a las importaciones de OpenZeppelin:

1. **Aplanar el contrato**: En Remix, click derecho en el archivo → "Flatten"
2. **Copiar el código aplanado**
3. **Ir a Etherscan**: Tu contrato → "Contract" → "Verify and Publish"
4. **Completar el formulario**:
   - Compiler: `v0.8.26`
   - Optimization: Yes (200 runs)
   - License: MIT
   - Pegar código aplanado
   - Constructor args (ABI-encoded)
5. **Verificar**

**Nota:** El aplanado fue necesario porque Etherscan tiene problemas verificando contratos con múltiples importaciones de OpenZeppelin cuando se despliegan desde Remix.

### Parámetros del Constructor

- `_withdrawalLimitUSD` (uint256): Límite máximo por retiro en USD (6 decimals)
- `_bankCapUSD` (uint256): Capacidad del banco en USD (6 decimals)
- `_ethPriceFeed` (address): Dirección del Chainlink ETH/USD Price Feed

**Sepolia Chainlink Price Feeds:**
- ETH/USD: `0x694AA1769357215DE4FAC081bf1f309aDC325306`

## 🔧 Cómo Interactuar

### Depositar ETH

```javascript
// Usando ethers.js v6
const amount = ethers.parseEther("0.01");
await contract.depositNative({ value: amount });
```

### Depositar ERC-20

```javascript
// 1. Aprobar el token
const tokenContract = new ethers.Contract(tokenAddress, ERC20_ABI, signer);
await tokenContract.approve(contractAddress, amount);

// 2. Depositar
await contract.depositERC20(tokenAddress, amount);
```

### Retirar

```javascript
// ETH
await contract.withdrawNative(ethers.parseEther("0.005"));

// ERC-20
await contract.withdrawERC20(tokenAddress, amount);
```

### Consultas

```javascript
// Balance de ETH (usa address(0))
const ethBalance = await contract.getVaultBalance(
    userAddress, 
    "0x0000000000000000000000000000000000000000"
);

// Balance de token ERC-20
const tokenBalance = await contract.getVaultBalance(userAddress, tokenAddress);

// Total depositado en USD
const totalUSD = await contract.getTotalDepositsUSD();

// Precio actual ETH/USD
const ethPrice = await contract.getETHPriceUSD();
```

## Decisiones de Diseño y Trade-offs

### 1. Normalización a 6 Decimales
**Decisión:** Usar 6 decimals como estándar interno (USDC)
**Causa:** 
- USDC es una de las stablecoin más usada en DeFi
- Facilita la contabilidad multi-token
- Reduce riesgos de overflow en cálculos de USD

**Trade-off:** Pérdida mínima de precisión para tokens de >6 decimals

### 2. Chainlink como Oráculo
**Decisión:** Usar Chainlink Data Feeds para conversión ETH/USD
**Causa:**
- De lo mejor de la industria
- Datos confiables y descentralizados (por lo menos la mayoría)
- Monitoreo constante

**Trade-off:** Dependencia externa, gas extra por consulta

### 3. Control de Acceso Granular
**Decisión:** OpenZeppelin AccessControl en vez de Ownable
**Por qué:**
- Permite múltiples administradores
- Roles específicos para funciones críticas
- Facilita governance descentralizado futuro

**Trade-off:** Mayor complejidad inicial, más gas en deploy

### 4. address(0) para ETH Nativo
**Decisión:** Usar address(0) para representar ETH en mappings
**Por qué:**
- Convención establecida en la industria
- Unifica interfaz de consulta para native y ERC-20
- Evita crear struct separado

**Trade-off:** Requiere documentación clara para usuarios

### 5. ReentrancyGuard
**Decisión:** Proteger todas las funciones de transferencia
**Por qué:**
- ETH y algunos ERC-20 pueden tener hooks
- Prevención de ataques de reentrancy
- Costo marginal de gas aceptable

**Trade-off:** +2,400 gas por transacción aprox.

## 📊 Información del Contrato

### Testnet Deployment

- **Red**: Sepolia Testnet
- **Dirección**: `0x84b56f41fa6fcbcbfa598a15d31e6e975247099c`
- **Explorador**: [Ver en Etherscan](https://sepolia.etherscan.io/address/0x84b56f41fa6fcbcbfa598a15d31e6e975247099c)
- **TX de Deploy**: [0xce3aae...66c028](https://sepolia.etherscan.io/tx/0xce3aaecb35504770b469da0e997719f3d763a13682cb581a909fb2a5cb66c028)
- **Verificado**: Sí (aplanado)

### Configuración Inicial
- **Límite de Retiro**: 1,000 USD (1000000000 en 6 decimals)
- **Capacidad del Banco**: 100,000 USD (100000000000 en 6 decimals)
- **Oráculo**: Chainlink ETH/USD Sepolia (`0x694AA1769357215DE4FAC081bf1f309aDC325306`)

## Estructura del Proyecto

```
KipuBankV2/
├── src/
│   └── KipuBankV2.sol
├── LICENSE
└── README.md
```

## 📄 Licencia

MIT License

## 🔗 Links Útiles

- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Chainlink Data Feeds](https://docs.chain.link/data-feeds)
- [Foundry Book](https://book.getfoundry.sh/)
- [Sepolia Testnet](https://sepolia.etherscan.io/)

---

**⚠️ Disclaimer**: Este contrato fue desarrollado con fines educativos para el Módulo 3 de EDP. Se recomienda auditoría profesional antes de uso en producción.

**Contacto**: sec***@gmail.com

---

*V2 desarrollado con ❤️ aplicando todo lo aprendido en el curso*
