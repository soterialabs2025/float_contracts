
type TokenPoolPair = {
  tokenAddress: string;
  poolAddress: string; // hard-coded pool address for this token
};
const TOKEN_POOL_PAIRS: TokenPoolPair[] = [
  
  // 1 - $2.80M Liquidity  Volitility 0.0326 2 Mil Liquidity 80K 24h Volume
  { tokenAddress: "0x1bc0c42215582d5a085795f4badbac3ff36d1bcb", poolAddress: "0xc1a6fbedae68e1472dbb91fe29b51f7a0bd44f97" },

  // 2 - $2.44M Liquidity  Volitility 0.2650  L - $2.43M V - 644.12K
  { tokenAddress: "0x22af33fe49fd1fa80c7149773dde5890d3c76f3b", poolAddress: "0xaec085e5a5ce8d96a7bdd3eb3a62445d4f6ce703" },

  // 3 Fair- $277.97K Liquidity  Volitility 0.1328  L - 78.65K V - 37.01K
  { tokenAddress: "0x7d928816cc9c462dd7adef911de41535e444cb07", poolAddress: "0xfc01837343cfc2a9ddca9e8a0a19825f6b2f0460" },
  // 4 - $40K
  // { tokenAddress: "0xa1f72459dfa10bad200ac160ecd78c6b77a747be", poolAddress: "0x07da9c5d35028f578dfac5be6e5aaa8a835704f6" },

  // 5 -noice $322K Liquidity  Volitility 0.0942l -358.33K V - 33.77K
  { tokenAddress: "0x9cb41fd9dc6891bae8187029461bfaadf6cc0c69", poolAddress: "0xeff7f8fe083d7a446717b992bf84391253e54789" },

  // 6 $52.73K Liquidity  Volitility 0.4649
  // { tokenAddress: "0x290f057a2c59b95d8027aa4abf31782676502071", poolAddress: "0x76c0106bba123e9b32770b2b34b6d13bf4cfa933" },

  // 7 clawd $208.54K Liquidity   Volitility 0.0292 l -1.15M V - 33.62K
  // { tokenAddress: "0x9f86db9fc6f7c9408e8fda3ff8ce4e78ac7a6b07", poolAddress: "0xcd55381a53da35ab1d7bc5e3fe5f76cac976fac3" },

  // 8 REI 359.09K Liquidity  Volitility 0.1390
  { tokenAddress: "0x6b2504a03ca4d43d0d73776f6ad46dab2f2a4cfd", poolAddress: "0xa213c82265cd3d94f972f735a4f5130e34df81bc" },

  // 9 AMETA  $138.63K Liquidity  Volitility 0.2541
  // { tokenAddress: "0x90ec58ef4cc9f37b96de1e203b65bd4e6e79580e", poolAddress: "0xfb559d225343a61884d46eee91c1a805759f758b" },

  // 10 DRB $793.47K Liquidity  Volitility 0.1341 
  { tokenAddress: "0x3ec2156d4c0a9cbdab4a016633b7bcf6a8d68ea2", poolAddress: "0x5116773e18a9c7bb03ebb961b38678e45e238923" },

  // 11  VVV $146.21K Liquidity Volitility 0.7916
  // { tokenAddress: "0xacfe6019ed1a7dc6f7b508c02d1b04ec88cc21bf", poolAddress: "0x1d2bdb7117a5a7d7fe4c1d95681a92e4df13bb69" },

  // 12 - FAI $256.02K Liquidity     Volitility 0.0173
  { tokenAddress: "0xb33ff54b9f7242ef1593d2c9bcd8f9df46c77935", poolAddress: "0x68b27e9066d3aadc6078e17c8611b37868f96a1d" },

  // 13 - AUKI 389.08K Liquidity Volitilit 0.1583
  { tokenAddress: "0xf9569cfb8fd265e91aa478d86ae8c78b8af55df4", poolAddress: "0x2fa9d6085c91151200e61a3e627d35001772c0d1" },

  // 14 - $90.94K Liquidity Volitility 0.4649
  // { tokenAddress: "0xd20ab1015f6a2de4a6fddebab270113f689c2f7c", poolAddress: "0xebdeacaf03ba54eb18128fd1fd042bc747af9295" },

  // 16 - $10.19K Volitility 0.4649
  // { tokenAddress: "0x767a739d1a152639e9ea1d8c1bd55fdc5b217d7f", poolAddress: "0x7f1a5b66ba3bb56c4b68cfc353a5e041c9763a4c" },

  // 18 - PARTI $324.79K Liquidity Volitility 0.4649
  { tokenAddress: "0x59264f02d301281f3393e1385c0aefd446eb0f00", poolAddress: "0x9c42751954513c0461481a9600c9d11a059ddd12" },

  // 19 - Circle $213.44K Liquidity Volitility 0.0255
  { tokenAddress: "0x5babfc2f240bc5de90eb7e19d789412db1dec402", poolAddress: "0xda679706ff21114ac9fac5198bff24543f357a16" },

  // 20 - doginime $1.36M Liquidity Volitility 0.0401
  { tokenAddress: "0x6921b130d297cc43754afba22e5eac0fbf8db75b", poolAddress: "0xade9bcd4b968ee26bed102dd43a55f6a8c2416df" },

  // 21  - $268.93K Liquidity Volitility 0.4649
  { tokenAddress: "0x2f6c17fa9f9bc3600346ab4e48c0701e1d5962ae", poolAddress: "0xfdbaf04326acc24e3d1788333826b71e3291863a" },

  // 22 - ZFI $212.73K Liquidity Volitility 0.0199
  { tokenAddress: "0xd080ed3c74a20250a2c9821885203034acd2d5ae", poolAddress: "0xc6f63e4bea6682aa502ed94c1301b56230fc03d2" },

  // 23 QR $130.57K Liquidity Volitility 0.0126
  // { tokenAddress: "0x2b5050f01d64fbb3e4ac44dc07f0732bfb5ecadf", poolAddress: "0xf02c421e15abdf2008bb6577336b0f3d7aec98f0" },

  // 24 - $33.99K Liquidity Volitility 0.0080
  // { tokenAddress: "0xf0197f10ea542a67914ecc0ec5304dc9df1faf6f", poolAddress: "0xba9d9445e0abdb6764ad6923feb04f12e863a616" },

    // 24 - FLUID $252.95K Liquidity    Volitility 0.0922
    { tokenAddress: "0x61e030a56d33e8260fdd81f03b162a79fe3449cd", poolAddress: "0x3b3d1a85a248b70100e95437dbeebcae5e7ec7a1" },

  // 24 - Toshi 1.42M Liquidity    Volitility 0.0172
  { tokenAddress: "0xac1bd2486aaf3b5c0fc3fd868558b082a531b2b4", poolAddress: "0x4b0aaf3ebb163dd45f663b38b6d93f6093ebc2d3" },

  // 24 - Flayer $238.35K Liquidity    Volitility 0.0094
  { tokenAddress: "0xf1a7000000950c7ad8aff13118bb7ab561a448ee", poolAddress: "0x7b9fda92bfa6fdadfdc4f6c72c0cc8336e7d7497" },
];

const TOKEN_POOL_PAIRS_V4: TokenPoolPairV4[] = [
  // 1 - $507.81K Liquidity - 1% Fee - SAIRI 2.4K Holders 24h Volume 116K USD Volitility 0.2375
  // 0xde61878b0b21ce395266c44d4d548d1c72a3eb07 = ["0x4200000000000000000000000000000000000006","0xde61878b0b21ce395266c44d4d548d1c72a3eb07",8388608,200,"0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc"]
  {
    tokenAddress: "0xde61878b0b21ce395266c44d4d548d1c72a3eb07",
    poolAddress: "0x8e1737aab1bb49dcdbfa014868c1cfb8702b7b66ce20e023e7d6f7427f9e1537",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0xde61878b0b21ce395266c44d4d548d1c72a3eb07",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc",
    },
  },
  // 2 - $504.59K Liquidity - 1.2% Fee - Name: MiroShark. 1.4K Holders 24h Volume 757K USD Volitility 1.40
  // 0xd7bc6a05a56655fb2052f742b012d1dfd66e1ba3 = ["0x4200000000000000000000000000000000000006","0xd7bc6a05a56655fb2052f742b012d1dfd66e1ba3",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]
  {
    tokenAddress: "0xd7bc6a05a56655fb2052f742b012d1dfd66e1ba3",
    poolAddress: "0x83a29b6619907f80e5a47d40f53d4af239a69980f22a08b10f43d357a9f06209",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0xd7bc6a05a56655fb2052f742b012d1dfd66e1ba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbb7784a4d481184283ed89619a3e3ed143e1adc0",
    },
  },
  // 3 - 201.20K Liquidity - 1.2% Fee - Name: EDGE. 700 Holders 24h Volume 277K USD Volitility 1.63
  // 0x62abe92f50c518165a5c010fe59f35023197fba3 = ["0x4200000000000000000000000000000000000006","0x62abe92f50c518165a5c010fe59f35023197fba3",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]
  {
    tokenAddress: "0x62abe92f50c518165a5c010fe59f35023197fba3",
    poolAddress: "0xd10a903640f598f257e6fb68742ad4126a3727b7f97adf9e83d17e907aaae704",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x62abe92f50c518165a5c010fe59f35023197fba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbb7784a4d481184283ed89619a3e3ed143e1adc0",
    },
  },
  // 4 - $615.23K Liquidity - 1.2% Fee - Name: Litcoin. 2.32K Holders 24h Volume 168.33K USD Volitility 0.4649
  // 0x316ffb9c875f900adcf04889e415cc86b564eba3 = ["0x316ffb9c875f900adcf04889e415cc86b564eba3","0x4200000000000000000000000000000000000006",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]
  {
    tokenAddress: "0x316ffb9c875f900adcf04889e415cc86b564eba3",
    poolAddress: "0xfd3e3e7fe5958221532ab8f56c0dd08379740797a7d03db8a4e975b524010a31",
    poolKey: {
      currency0: "0x316ffb9c875f900adcf04889e415cc86b564eba3",
      currency1: "0x4200000000000000000000000000000000000006",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbb7784a4d481184283ed89619a3e3ed143e1adc0",
    },
  },
  // 5 - $1.20M Liquidity - 1.02% Fee - Name: LienFi.  5.73K Holders 24h Volume 645.K USD Volitility 0.5079
  // 0x3722264ab15a1dfce5a5af89e6547f7949a8aba3 = ["0x3722264ab15a1dfce5a5af89e6547f7949a8aba3","0x4200000000000000000000000000000000000006",8388608,200,"0xbdf938149ac6a781f94faa0ed45e6a0e984c6544"]
  {
    tokenAddress: "0x3722264ab15a1dfce5a5af89e6547f7949a8aba3",
    poolAddress: "0x6ef02666f150d9649655b884e043b61b0990fad9be4c632d0c7568bb24da9367",
    poolKey: {
      currency0: "0x3722264ab15a1dfce5a5af89e6547f7949a8aba3",
      currency1: "0x4200000000000000000000000000000000000006",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbdf938149ac6a781f94faa0ed45e6a0e984c6544",
    },
  },
  // 6 $1.38M Liquidity - 1% Fee - Name: ClawBank.  3.52K Holders 24h Volume 615.87K USD Volitility 0.4344
  // 0x16332535e2c27da578bc2e82beb09ce9d3c8eb07 = ["0x16332535e2c27da578bc2e82beb09ce9d3c8eb07","0x4200000000000000000000000000000000000006",8388608,200,"0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc"]
  {
    tokenAddress: "0x16332535e2c27da578bc2e82beb09ce9d3c8eb07",
    poolAddress: "0xb04b187062efbf94cf9b4b6f42bf688258d3c88b7c9283bbc74dbbfb1af40d54",
    poolKey: {
      currency0: "0x16332535e2c27da578bc2e82beb09ce9d3c8eb07",
      currency1: "0x4200000000000000000000000000000000000006",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc",
    },
  },
  // 7 $3.31 M Liquidity - 1.2% Fee - Name: gitlawb. 4.82K Holders 24h Volume 2.07M USD Volitility 00.5650
  // 0x5f980dcfc4c0fa3911554cf5ab288ed0eb13dba3 = ["0x4200000000000000000000000000000000000006","0x5f980dcfc4c0fa3911554cf5ab288ed0eb13dba3",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]
  {
    tokenAddress: "0x5f980dcfc4c0fa3911554cf5ab288ed0eb13dba3",
    poolAddress: "0xec33256bf1ded407a57fd3c1965e7556e42ac14db09bc4e6fef57d5e2eb0b0b9",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x5f980dcfc4c0fa3911554cf5ab288ed0eb13dba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbb7784a4d481184283ed89619a3e3ed143e1adc0",
    },
  },
  // 8 $361.93K Liquidity - 1.2% Fee - Name: Helixa Cred. 13.9K Holders 24h Volume 60.19K USD Volitility 0.3005
  // 0xab3f23c2abcb4e12cc8b593c218a7ba64ed17ba3 = ["0x4200000000000000000000000000000000000006","0xab3f23c2abcb4e12cc8b593c218a7ba64ed17ba3",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]
  {
    tokenAddress: "0xab3f23c2abcb4e12cc8b593c218a7ba64ed17ba3",
    poolAddress: "0x55a4f7a23c4c2616cf848e639a08bd4283d13e66f5fcf34f828b5ca7e4e96324",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0xab3f23c2abcb4e12cc8b593c218a7ba64ed17ba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbb7784a4d481184283ed89619a3e3ed143e1adc0",
    },
  },
  // 9 $998.82KLiquidity  - 1% Fee - Name: CLAWNCH. 1.35K Holders 24h Volume 109.61K USD Volitility 0.0602
  // 0xa1f72459dfa10bad200ac160ecd78c6b77a747be = ["0x4200000000000000000000000000000000000006","0xa1f72459dfa10bad200ac160ecd78c6b77a747be",8388608,200,"0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc"]
  {
    tokenAddress: "0xa1f72459dfa10bad200ac160ecd78c6b77a747be",
    poolAddress: "0x03d3c21ea1daf51dd2898ebaf9342a93374877ba6ab34cc7ffe5b5d43ee46e0a",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0xa1f72459dfa10bad200ac160ecd78c6b77a747be",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc",
    },
  },
  // 10 $1.58M Liquidity - 1% Fee - Name: Moltbook. 27.53K Holders 24h Volume 57.52K USD Volitility 0.0356
  // 0xb695559b26bb2c9703ef1935c37aeae9526bab07 = ["0x4200000000000000000000000000000000000006","0xb695559b26bb2c9703ef1935c37aeae9526bab07",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]
  {
    tokenAddress: "0xb695559b26bb2c9703ef1935c37aeae9526bab07",
    poolAddress: "0x15f351bf1637b43d70631ba95fb9bbb1ff21761c29b034c1b380aecb922464dd",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0xb695559b26bb2c9703ef1935c37aeae9526bab07",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbb7784a4d481184283ed89619a3e3ed143e1adc0",
    },
  },
  // 11 $592.65K Liquidity - 1.2% Fee - Name: nook. 2.63K Holders 24h Volume 121.49K USD Volitility 0.2048
  // 0xb233bdffd437e60fa451f62c6c09d3804d285ba3 = ["0x4200000000000000000000000000000000000006","0xb233bdffd437e60fa451f62c6c09d3804d285ba3",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]
  {
    tokenAddress: "0xb233bdffd437e60fa451f62c6c09d3804d285ba3",
    poolAddress: "0xe93071444b085fe0b83b0e138c2f0e47d510c1f6fa604a83dd10c0c7f8a0bb97",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0xb233bdffd437e60fa451f62c6c09d3804d285ba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbb7784a4d481184283ed89619a3e3ed143e1adc0",
    },
  },
  // 12 - $465.51K Liquidity - .7% Fee -Name: Hermes OS 1.9K Holders 24h Volume 573.30K USD Volitility 1.19
  // 0x95ccfd2b81a9667b0cc979992632f98fc853eba3 = ["0x4200000000000000000000000000000000000006","0x95ccfd2b81a9667b0cc979992632f98fc853eba3",8388608,200,"0xbdf938149ac6a781f94faa0ed45e6a0e984c6544"]
  {
    tokenAddress: "0x95ccfd2b81a9667b0cc979992632f98fc853eba3",
    poolAddress: "0x336ad40640593281d9c519fa0994986817fce079a0c493ea08f7ed9cac55ff19",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x95ccfd2b81a9667b0cc979992632f98fc853eba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbdf938149ac6a781f94faa0ed45e6a0e984c6544",
    },
  },
  // 13 - $899.17K Liquidity - 1% Fee - Name: KellyClaude 6.93K Holders 24h Volume 91.74K USD Volitility 0.1021
  // 0x50d2280441372486beecdd328c1854743ebacb07 = ["0x4200000000000000000000000000000000000006","0x50d2280441372486beecdd328c1854743ebacb07",8388608,200,"0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc"]
  {
    tokenAddress: "0x50d2280441372486beecdd328c1854743ebacb07",
    poolAddress: "0x7eac33d5641697366eaec3234147fd98ba25f01acca66a51a48bd129fc532145",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x50d2280441372486beecdd328c1854743ebacb07",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc",
    },
  },
  // 14 - $505.78K Liquidity - 1% Fee - Name: Juno. 3.22K Holders 24h Volume 262.10K USD - Volitility 0.51
  // 0x4e6c9f48f73e54ee5f3ab7e2992b2d733d0d0b07 = ["0x4200000000000000000000000000000000000006","0x4e6c9f48f73e54ee5f3ab7e2992b2d733d0d0b07",8388608,200,"0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc"]
  {
    tokenAddress: "0x4e6c9f48f73e54ee5f3ab7e2992b2d733d0d0b07",
    poolAddress: "0x1635213e2b19e459a4132df40011638b65ae7510a35d6a88c47ebf94912c7f2e",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x4e6c9f48f73e54ee5f3ab7e2992b2d733d0d0b07",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc",
    },
  },
  // 16 - $242.84K Liquidity - 1..2% Fee - Name: Darksol. 871 Holders 24h Volume 229.66K USD Volitility 0.9457
  // 0x00cb1fbca324d51325a7264d54072bc073c28ba3 = ["0x00cb1fbca324d51325a7264d54072bc073c28ba3","0x4200000000000000000000000000000000000006",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]
  {
    tokenAddress: "0x00cb1fbca324d51325a7264d54072bc073c28ba3",
    poolAddress: "0xca9e6410406dd333b2761db109162c9943ea8a112048d5d4d87dd900f5b8369a",
    poolKey: {
      currency0: "0x00cb1fbca324d51325a7264d54072bc073c28ba3",
      currency1: "0x4200000000000000000000000000000000000006",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbb7784a4d481184283ed89619a3e3ed143e1adc0",
    },
  },
  // 18 - $280.93K Liquidity - 1% Fee - Name: Doppel. 3.91K  Holders 24h Volume 273.87K USD Volitility 0.9748
  // 0xf27b8ef47842e6445e37804896f1bc5e29381b07 = ["0x4200000000000000000000000000000000000006","0xf27b8ef47842e6445e37804896f1bc5e29381b07",8388608,200,"0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc"]
  {
    tokenAddress: "0xf27b8ef47842e6445e37804896f1bc5e29381b07",
    poolAddress: "0x87e22831f5b0b48759b9113128d1472a97e366ae777da0de2c990cb82d739b54",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0xf27b8ef47842e6445e37804896f1bc5e29381b07",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc",
    },
  },
  // 19 - $411.27K Liquidity - 1% Fee -  Name: FELIX. 6.63K Holders 24h Volume 27.05K USD Volitility 0.0657
  // 0xf30bf00edd0c22db54c9274b90d2a4c21fc09b07 = ["0x4200000000000000000000000000000000000006","0xf30bf00edd0c22db54c9274b90d2a4c21fc09b07",8388608,200,"0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc"]
  {
    tokenAddress: "0xf30bf00edd0c22db54c9274b90d2a4c21fc09b07",
    poolAddress: "0x6e19027912db90892200a2b08c514921917bc55d7291ec878aa382c193b50084",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0xf30bf00edd0c22db54c9274b90d2a4c21fc09b07",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc",
    },
  },
  // 20 - $218.94K Liquidity - 1% Fee - Name: BitVault. Signal 810 Holders 24h Volume 9.96K  USD Volitility 0.0454
  // 0xd88fd4a11255e51f64f78b4a7d74456325c2d8dc = ["0x4200000000000000000000000000000000000006","0xd88fd4a11255e51f64f78b4a7d74456325c2d8dc",8388608,200,"0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc"]
  {
    tokenAddress: "0xd88fd4a11255e51f64f78b4a7d74456325c2d8dc",
    poolAddress: "0x8de32c3e440d497cd3b607555be1f6115717965fff56247c02976814edcf384f",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0xd88fd4a11255e51f64f78b4a7d74456325c2d8dc",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc",
    },
  }, 
  // 21  - $1.25M Liquidity - 1% Fee - Name: clawd. - 15.42K Holders 24h Volume 49.75K USD Volitility 0.0394
  // 0x9f86db9fc6f7c9408e8fda3ff8ce4e78ac7a6b07 = ["0x4200000000000000000000000000000000000006","0x9f86db9fc6f7c9408e8fda3ff8ce4e78ac7a6b07",8388608,200,"0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc"]
  {
    tokenAddress: "0x9f86db9fc6f7c9408e8fda3ff8ce4e78ac7a6b07",
    poolAddress: "0x9fd58e73d8047cb14ac540acd141d3fc1a41fb6252d674b730faf62fe24aa8ce",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x9f86db9fc6f7c9408e8fda3ff8ce4e78ac7a6b07",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc",
    },
  },
  // 22 - $396.76K Liquidity - 1% Fee - Name: Molten. - Added 3.78K Holders 24h Volume 17.96K USD Volitility 0.0452
  // 0x59c0d5c34c301ac0600147924d6c9be22a2f0b07 = ["0x4200000000000000000000000000000000000006","0x59c0d5c34c301ac0600147924d6c9be22a2f0b07",8388608,200,"0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc"]
  {
    tokenAddress: "0x59c0d5c34c301ac0600147924d6c9be22a2f0b07",
    poolAddress: "0x5d58fdc2eea2e365c8c476a15a61635804796fd891d9b348bbe514c0417ea070",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x59c0d5c34c301ac0600147924d6c9be22a2f0b07",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc",
    },
  },
  // 23 $708.11K Liquidity - 1.2% Fee - Name: BOTCOIN. - Added 4.6K Holders 24h Volume 285.85K USD Volitility 0.3973
  // 0xa601877977340862ca67f816eb079958e5bd0ba3 = ["0x4200000000000000000000000000000000000006","0xa601877977340862ca67f816eb079958e5bd0ba3",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]
  {
    tokenAddress: "0xa601877977340862ca67f816eb079958e5bd0ba3",
    poolAddress: "0x5154ba0d6cfb5fe27644bc856064991e1c7672b7eb533d5d457db4c7144c2af5",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0xa601877977340862ca67f816eb079958e5bd0ba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbb7784a4d481184283ed89619a3e3ed143e1adc0",
    },
  },
  // 24 - $238.10K Liquidity - 1% Fee - Name: Regent. 2.33K Holders 24h Volume 960.45 USD Volitility 0.0040
  // 0x6f89bca4ea5931edfcb09786267b251dee752b07 = ["0x4200000000000000000000000000000000000006","0x6f89bca4ea5931edfcb09786267b251dee752b07",8388608,200,"0xd60d6b218116cfd801e28f78d011a203d2b068cc"]
  {
    tokenAddress: "0x6f89bca4ea5931edfcb09786267b251dee752b07",
    poolAddress: "0x4ed3b69ac263ad86482f609b2c2105f64bcfd3a7e02e8e078ec9fec1f0324bed",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x6f89bca4ea5931edfcb09786267b251dee752b07",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xd60d6b218116cfd801e28f78d011a203d2b068cc",
    },
  }, 
  // 25 - $233.51K Liquidity - 1% Fee - Name: SelfClaw. 186.92K Holders 24h Volume 57.52K USD Volitility 0.8005
  // 0x9ae5f51d81ff510bf961218f833f79d57bfbab07 = ["0x4200000000000000000000000000000000000006","0x9ae5f51d81ff510bf961218f833f79d57bfbab07",8388608,200,"0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc"]
  {
    tokenAddress: "0x9ae5f51d81ff510bf961218f833f79d57bfbab07",
    poolAddress: "0xac16d463fe6783fe82ec1b95db01d25daf7c2f9f523baa8d2c0ec7e707d4d568",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x9ae5f51d81ff510bf961218f833f79d57bfbab07",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc",
    },
  },
  
   // 25 -  $337.36K Liquidity - 1% Fee - Name:Cody. 186.92K Holders 24h Volume $1.47K USD Volitility 0.004
   //   // 0x3977fc913db86b01a257232c568317798b903b07 = ["0x4200000000000000000000000000000000000006","0x3977fc913db86b01a257232c568317798b903b07",8388608,200,"0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc"]
  {
    tokenAddress: "0x3977fc913db86b01a257232c568317798b903b07",
    poolAddress: "0xd93f984c201e72c04035d8ca02f54d9dfef23689471d6593fef1697a6a24a0a9",
    poolKey: {
      currency0: "0x3977fc913db86b01a257232c568317798b903b07",
      currency1: "0x4200000000000000000000000000000000000006",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0x34a45c6b61876d739400bd71228cbcbd4f53e8cc",
    },
  },
     // 26 - $388.09K Liquidity - 2% Fee - Name: Gitbank.  2.83K Holders 24h Volume 400K USD Volitility 1.03
   //   // 0xc21dd0ee043930711c2a3e55f39c7d3144d09b07 = ["0x4200000000000000000000000000000000000006","0xc21dd0ee043930711c2a3e55f39c7d3144d09b07",8388608,200,"0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc"]
   {
    tokenAddress: "0xc21dd0ee043930711c2a3e55f39c7d3144d09b07",
    poolAddress: "0xed3057cdc362b0724f454a00b8eb4f52e7b3ce98c562b4df51ff0adeb01d217a",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0xc21dd0ee043930711c2a3e55f39c7d3144d09b07",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc",
    },
  },

    // 27 - $842K Liquidity - 2% Fee - Name: Supergemma4.- 842K 2000 Holders 24h Volume $1.55M USD Volitility 1.84
   //   // 0x572c4fa77623652411574c51b5ddb7e1b750aba3 = ["0x4200000000000000000000000000000000000006","0x572c4fa77623652411574c51b5ddb7e1b750aba3",8388608,200,"0xbdf938149ac6a781f94faa0ed45e6a0e984c6544"]
   {
    tokenAddress: "0x572c4fa77623652411574c51b5ddb7e1b750aba3",
    poolAddress: "0x7016371c9642e346094b51b9603e429828d3f8063537770020115af81b019145",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x572c4fa77623652411574c51b5ddb7e1b750aba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbdf938149ac6a781f94faa0ed45e6a0e984c6544",
    },
  },

  // 28 - $439K Liquidity - .7% Fee - Name: grantr.-  1.43 Holders 24h Volume $362K USD Volitility .8235
   //   // 0x753f2af0f46361c9ae6fc347797f99b0c9e82ba3 = ["0x4200000000000000000000000000000000000006","0x753f2af0f46361c9ae6fc347797f99b0c9e82ba3",8388608,200,"0xbdf938149ac6a781f94faa0ed45e6a0e984c6544"]
   {
    tokenAddress: "0x753f2af0f46361c9ae6fc347797f99b0c9e82ba3",
    poolAddress: "0x9196ada2ee67f89f347a59c2615057e3dcea28a7697020fd86f37e63f5c2d67a",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x753f2af0f46361c9ae6fc347797f99b0c9e82ba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbdf938149ac6a781f94faa0ed45e6a0e984c6544",
    },
  },
    // 28 - $292.96K Liquidity - .7% Fee - Name: wake.-  866 Holders 24h Volume $188.65K USD Volitility 0.6420
   //   // 0x50c2cc97c4f487aa0cd742ab4b6afe8b8511bba3 = ["0x4200000000000000000000000000000000000006","0x50c2cc97c4f487aa0cd742ab4b6afe8b8511bba3",8388608,200,"0xbdf938149ac6a781f94faa0ed45e6a0e984c6544"]
   {
    tokenAddress: "0x50c2cc97c4f487aa0cd742ab4b6afe8b8511bba3",
    poolAddress: "0x9196ada2ee67f89f347a59c2615057e3dcea28a7697020fd86f37e63f5c2d67a",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x50c2cc97c4f487aa0cd742ab4b6afe8b8511bba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbdf938149ac6a781f94faa0ed45e6a0e984c6544",
    },
  },
  // 29 aeon  - 
     // 0xbf8e8f0e8866a7052f948c16508644347c57aba3 = ["0x4200000000000000000000000000000000000006","0xbf8e8f0e8866a7052f948c16508644347c57aba3",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]
   {
    tokenAddress: "0xbf8e8f0e8866a7052f948c16508644347c57aba3",
    poolAddress: "0x4a9b9e13975d26f4e3e17c655593bb82145dd4452aedafb826d856b817c9cfd4",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0xbf8e8f0e8866a7052f948c16508644347c57aba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbb7784a4d481184283ed89619a3e3ed143e1adc0",
    },
  },
  
  // 30 Berry - 
  //   // 0x778d347b2ffbadf31a2a1be9cf42b4c7ba8b1ba3 = ["0x4200000000000000000000000000000000000006","0x778d347b2ffbadf31a2a1be9cf42b4c7ba8b1ba3",8388608,200,"0xbdf938149ac6a781f94faa0ed45e6a0e984c6544"]
  {
    tokenAddress: "0x778d347b2ffbadf31a2a1be9cf42b4c7ba8b1ba3",
    poolAddress: "0xabacf9efd8f34eb11ea12be37dfccd32395f825ffeb4aa10a9177a0d9fed6327",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x778d347b2ffbadf31a2a1be9cf42b4c7ba8b1ba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbdf938149ac6a781f94faa0ed45e6a0e984c6544",
    },
  },

  // 31 Blocktronics — 
  //   // 0x7afe438411ee3959c7de6f7fb76bf9c769320ba3 = ["0x4200000000000000000000000000000000000006","0x7afe438411ee3959c7de6f7fb76bf9c769320ba3",8388608,200,"0xbdf938149ac6a781f94faa0ed45e6a0e984c6544"]
  {
    tokenAddress: "0x7afe438411ee3959c7de6f7fb76bf9c769320ba3",
    poolAddress: "0x7f36b7889aaf2268e8a39865f02451c102bf9070d94569034fc011d6349d9dd8",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x7afe438411ee3959c7de6f7fb76bf9c769320ba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbdf938149ac6a781f94faa0ed45e6a0e984c6544",
    },
  },

  // 32 Orlix AI — 
  //   // 0x799c28bac95b3e0b26534d1e9a586511895ecba3 = ["0x4200000000000000000000000000000000000006","0x799c28bac95b3e0b26534d1e9a586511895ecba3",8388608,200,"0xbdf938149ac6a781f94faa0ed45e6a0e984c6544"]
  {
    tokenAddress: "0x799c28bac95b3e0b26534d1e9a586511895ecba3",
    poolAddress: "0xf11c9dc85be5fda498a34525bfa9d13177934149068c57bb17133f0156fabe16",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x799c28bac95b3e0b26534d1e9a586511895ecba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbdf938149ac6a781f94faa0ed45e6a0e984c6544",
    },
  },

  // 33 1claw AI — 
  //   // 0x61d91cff0fc9fbbdb89f505cf8a7422bf95fdba3 = ["0x4200000000000000000000000000000000000006","0x61d91cff0fc9fbbdb89f505cf8a7422bf95fdba3",8388608,200,"0xbdf938149ac6a781f94faa0ed45e6a0e984c6544"]
  {
    tokenAddress: "0x61d91cff0fc9fbbdb89f505cf8a7422bf95fdba3",
    poolAddress: "0xf80335f8d6ba2a5970474a236bec053a65de6ca6fa1cd1f80086d843fef112bb",
    poolKey: {
      currency0: "0x4200000000000000000000000000000000000006",
      currency1: "0x61d91cff0fc9fbbdb89f505cf8a7422bf95fdba3",
      fee: 8388608,
      tickSpacing: 200,
      hooks: "0xbdf938149ac6a781f94faa0ed45e6a0e984c6544",
    },
  },

  // 34 evo- — 
//   // 0x721b072dbb616f29eea73ac004e03fd4e884bba3 = ["0x4200000000000000000000000000000000000006","0x721b072dbb616f29eea73ac004e03fd4e884bba3",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]
{
  tokenAddress: "0x721b072dbb616f29eea73ac004e03fd4e884bba3",
  poolAddress: "0xd8ee119a65d3a902ced4ef7693b98e62a7fbb1d7808a693dbb6961d7f544fb80",
  poolKey: {
    currency0: "0x4200000000000000000000000000000000000006",
    currency1: "0x721b072dbb616f29eea73ac004e03fd4e884bba3",
    fee: 8388608,
    tickSpacing: 200,
    hooks: "0xbb7784a4d481184283ed89619a3e3ed143e1adc0",
  },
},


  // 34 Surplus- — 
  // 0xc52aedec3374422d7510e294cfaa90799595cba3 = ["0x4200000000000000000000000000000000000006","0xc52aedec3374422d7510e294cfaa90799595cba3",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]
{
  tokenAddress: "0xc52aedec3374422d7510e294cfaa90799595cba3",
  poolAddress: "0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a",
  poolKey: {
    currency0: "0x4200000000000000000000000000000000000006",
    currency1: "0xc52aedec3374422d7510e294cfaa90799595cba3",
    fee: 8388608,
    tickSpacing: 200,
    hooks: "0xbb7784a4d481184283ed89619a3e3ed143e1adc0",
  },
},

];
