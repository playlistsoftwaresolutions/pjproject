#!/bin/bash

# Script de build da PJSIP para iOS - Todas as arquiteturas
# Uso: ./build-pjsip-ios.sh [caminho/para/pjsip]

clear

set -e  # Sai do script se qualquer comando falhar

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configurações
MIN_IOS_VERSION="13.0"
PJSIP_DIR=${1:-$(pwd)}  # Usa o diretório atual se não for especificado
BUILD_DIR="$PJSIP_DIR/build-ios"
LOG_FILE="$BUILD_DIR/build.log"
PARENT_DIR="$(cd "$(dirname "$PJSIP_DIR")" && pwd)"
OPENSSL_DIR="$PARENT_DIR/openssl-1.1.1"

# Arquiteturas alvo
#IOS_ARCHS=("arm64" "armv7")
#SIMULATOR_ARCHS=("arm64" "x86_64")
IOS_ARCHS=("arm64")
SIMULATOR_ARCHS=("x86_64")

# Função para log
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERRO] $1${NC}" >&2
    echo "[ERRO] $1" >> "$LOG_FILE"
    exit 1
}

warning() {
    echo -e "${YELLOW}[AVISO] $1${NC}"
    echo "[AVISO] $1" >> "$LOG_FILE"
}

# Função para verificar pré-requisitos
check_prerequisites() {
    log "Verificando pré-requisitos..."
    
    # Verifica se está no diretório da PJSIP
    if [ ! -f "$PJSIP_DIR/configure-iphone" ]; then
        error "configure-iphone não encontrado em $PJSIP_DIR. Certifique-se de estar no diretório da PJSIP ou forneça o caminho correto."
    fi
    
    # Verifica Xcode
    if ! xcode-select -p &> /dev/null; then
        error "Xcode Command Line Tools não encontrados."
    fi
    
    # Verifica ferramentas necessárias
    for tool in make libtool lipo; do
        if ! command -v $tool &> /dev/null; then
            error "$tool não encontrado. Instale as ferramentas de linha de comando do Xcode."
        fi
    done
    
    log "Pré-requisitos OK"
}

# Função para configurar config_site.h
setup_config_site() {
    log "Configurando config_site.h..."
    log "config_site.h configurado em $CONFIG_SITE"
}

# Função para extrair o nome base da biblioteca (remove sufixo de arquitetura)
get_base_lib_name() {
    local filename=$1
    # Remove padrões como -arm64-apple-darwin_ios, -x86_64-apple-darwin_ios, etc
    echo "$filename" | sed -E 's/-[^-]+-apple-darwin_ios//g'
}

# Função para build para uma arquitetura específica
build_architecture() {
    local arch=$1
    local platform=$2  # "ios" ou "simulator"
    local build_path="$BUILD_DIR/$platform-$arch"
    
    log "Construindo para $platform - $arch..."
    
    mkdir -p "$build_path"
    cd "$PJSIP_DIR"
    
    # Limpa builds anteriores (mas não falha se não conseguir)
    make distclean &> /dev/null || true
    
    # Configura variáveis de ambiente baseadas na plataforma
    if [ "$platform" == "ios" ]; then
        export DEVPATH="/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer"
        export ARCH="-arch $arch"
        export MIN_IOS="-miphoneos-version-min=$MIN_IOS_VERSION"
        unset CFLAGS LDFLAGS  # Limpa flags para device
    else  # simulator
        export DEVPATH="/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer"
        export ARCH="-arch $arch"
        export MIN_IOS="-mios-simulator-version-min=$MIN_IOS_VERSION"
        
        # Configurações específicas para simulator
        if [ "$arch" == "x86_64" ]; then
            export CFLAGS="-O2 -m64"
            export LDFLAGS="-O2 -m64"
        elif [ "$arch" == "arm64" ]; then
            export CFLAGS="-O2"
            export LDFLAGS="-O2"
        fi
    fi
    
    # Executa configure-iphone
    log "Executando configure-iphone para $arch..."
    ./configure-iphone --with-ssl=$OPENSSL_DIR >> "$LOG_FILE" 2>&1 || error "Falha no configure-iphone para $arch"
    
    # Build
    log "Compilando para $arch (isso pode levar alguns minutos)..."
    make dep >> "$LOG_FILE" 2>&1 || error "Falha no make dep para $arch"
    make clean >> "$LOG_FILE" 2>&1
    make >> "$LOG_FILE" 2>&1 || error "Falha no make para $arch"
    
    # Procura e copia as bibliotecas
    log "Coletando bibliotecas para $arch..."
    mkdir -p "$build_path/libs"
    
    # Procura por bibliotecas .a em vários locais possíveis
    find "$PJSIP_DIR" -name "*.a" -type f \
        -not -path "*/build-ios/*" \
        -exec cp {} "$build_path/libs/" 2>/dev/null \;
    
    # Renomeia as bibliotecas para remover os sufixos de arquitetura
    cd "$build_path/libs"
    for lib in *.a; do
        if [ -f "$lib" ]; then
            new_name=$(get_base_lib_name "$lib")
            if [ "$lib" != "$new_name" ]; then
                mv "$lib" "$new_name" 2>/dev/null || true
                log "  Renomeado: $lib -> $new_name"
            fi
        fi
    done
    
    # Verifica se copiou alguma biblioteca
    local lib_count=$(ls -1 "$build_path/libs"/*.a 2>/dev/null | wc -l)
    if [ "$lib_count" -eq 0 ]; then
        warning "Nenhuma biblioteca .a encontrada para $arch"
    else
        log "Copiadas $lib_count bibliotecas para $arch"
    fi
    
    log "Build concluído para $arch"
}

# Função para combinar bibliotecas com lipo (todas arquiteturas em uma pasta)
create_fat_libraries() {
    log "Criando bibliotecas universais (fat) com lipo (todas arquiteturas em uma pasta)..."
    
    # Diretório de saída único
    local FAT_IOS_DIR="$BUILD_DIR/fat-ios"
    
    mkdir -p "$FAT_IOS_DIR"
    
    # Limpa diretório fat antes de começar
    rm -f "$FAT_IOS_DIR"/*.a 2>/dev/null || true
    
    # Vamos usar a primeira arquitetura como referência para encontrar as bibliotecas
    local first_arch="${IOS_ARCHS[0]}"
    local reference_path="$BUILD_DIR/ios-$first_arch/libs"
    
    if [ ! -d "$reference_path" ]; then
        warning "Diretório de referência não encontrado: $reference_path"
        return 1
    fi
    
    local lib_count=0
    
    # Para cada biblioteca encontrada na arquitetura de referência
    for lib in "$reference_path"/*.a; do
        if [ -f "$lib" ]; then
            local lib_name=$(basename "$lib")
            local lipo_args=()
            local has_all_archs=true
            
            # Adiciona arquiteturas do iOS device
            for arch in "${IOS_ARCHS[@]}"; do
                local arch_lib="$BUILD_DIR/ios-$arch/libs/$lib_name"
                if [ -f "$arch_lib" ]; then
                    lipo_args+=("-arch" "$arch" "$arch_lib")
                else
                    log "  Biblioteca $lib_name não encontrada para iOS $arch"
                    has_all_archs=false
                    break
                fi
            done
            
            # Se tem todas as arquiteturas iOS, adiciona as do simulator
            if [ "$has_all_archs" = true ]; then
                for arch in "${SIMULATOR_ARCHS[@]}"; do
                    local arch_lib="$BUILD_DIR/simulator-$arch/libs/$lib_name"
                    if [ -f "$arch_lib" ]; then
                        lipo_args+=("-arch" "$arch" "$arch_lib")
                    else
                        log "  Biblioteca $lib_name não encontrada para Simulator $arch"
                        has_all_archs=false
                        break
                    fi
                done
            fi
            
            # Se encontrou todas as arquiteturas, cria o fat binary
            if [ "$has_all_archs" = true ] && [ ${#lipo_args[@]} -gt 0 ]; then
                log "Criando fat library com todas as arquiteturas: $lib_name"
                log "  Arquiteturas: ${IOS_ARCHS[*]} ${SIMULATOR_ARCHS[*]}"
                
                lipo "${lipo_args[@]}" -create -output "$FAT_IOS_DIR/$lib_name" || \
                    warning "Falha ao criar fat library para $lib_name"
                
                # Verifica o resultado
                if [ -f "$FAT_IOS_DIR/$lib_name" ]; then
                    local archs=$(lipo -info "$FAT_IOS_DIR/$lib_name" | sed 's/.*: //')
                    log "  Biblioteca criada com arquiteturas: $archs"
                    ((lib_count++))
                fi
            else
                log "  Pulando $lib_name - arquiteturas incompletas"
            fi
        fi
    done
    
    # Verifica os resultados
    local total_count=$(ls -1 "$FAT_IOS_DIR"/*.a 2>/dev/null | wc -l)
    
    log "Criadas $total_count bibliotecas universais em: $FAT_IOS_DIR"
    
    if [ $total_count -eq 0 ]; then
        warning "Nenhuma biblioteca encontrada para fazer lipo!"
    else
        # Mostra detalhes das bibliotecas criadas
        echo -e "\n${GREEN}Detalhes das bibliotecas universais criadas:${NC}"
        for lib in "$FAT_IOS_DIR"/*.a; do
            if [ -f "$lib" ]; then
                local lib_name=$(basename "$lib")
                local archs=$(lipo -info "$lib" | sed 's/.*: //')
                echo "  $lib_name: $archs"
            fi
        done
    fi
}

# Função para criar um arquivo de informação
create_info_file() {
    cat > "$BUILD_DIR/INFO.txt" << EOF
PJSIP iOS Build Information
===========================
Data do build: $(date)
Versão do iOS mínima: $MIN_IOS_VERSION
Arquiteturas iOS: ${IOS_ARCHS[*]}
Arquiteturas Simulator: ${SIMULATOR_ARCHS[*]}
Diretório PJSIP: $PJSIP_DIR

Arquivos gerados:
- Bibliotecas individuais por arquitetura: ios-{arch}/libs/ e simulator-{arch}/libs/
- Bibliotecas universais (fat): fat-ios/ e fat-simulator/
- Log: build.log

Para usar no Xcode:
1. Adicione as bibliotecas da pasta fat-ios/ (para device) ou fat-simulator/ (para simulator) ao seu projeto
2. Em Build Settings, adicione os headers:
   - Header Search Paths: \$(SRCROOT)/caminho/para/pjsip/**
3. Adicione as permissões necessárias no Info.plist:
   - NSCameraUsageDescription (para video)
   - NSMicrophoneUsageDescription (para audio)

EOF
    log "Arquivo INFO.txt criado"
}

# Função principal
main() {
    # Cria diretórios necessários ANTES de qualquer log
    mkdir -p "$BUILD_DIR"
    
    # Agora podemos usar o LOG_FILE
    echo "=== Início do build: $(date) ===" > "$LOG_FILE"
    
    log "=== Iniciando build da PJSIP para iOS ==="
    log "Diretório PJSIP: $PJSIP_DIR"
    log "Diretório de build: $BUILD_DIR"
    
    # Verifica pré-requisitos
    check_prerequisites
    
    # Configura config_site.h
    #setup_config_site
    
    # Build para iOS device
    log "=== Build para iOS Device ==="
    for arch in "${IOS_ARCHS[@]}"; do
        build_architecture "$arch" "ios"
        #echo $arch
    done
     
    # Build para Simulator
    log "=== Build para Simulator ==="
    for arch in "${SIMULATOR_ARCHS[@]}"; do
        build_architecture "$arch" "simulator"
        #echo $arch
    done
    
    # Combina bibliotecas com lipo
    log "=== Combinando bibliotecas com lipo ==="
    create_fat_libraries
    
    # Cria arquivo de informação
    create_info_file
    
    log "=== Build concluído com sucesso! ==="
    log "Bibliotecas fatiadas disponíveis em:"
    log "  - iOS Device: $BUILD_DIR/fat-ios/"
    log "  - Simulator: $BUILD_DIR/fat-simulator/"
    log "Log completo em: $LOG_FILE"
    log "Informações adicionais em: $BUILD_DIR/INFO.txt"
    
    # Mostra informações resumidas
    echo -e "\n${GREEN}Resumo do build:${NC}"
    echo "  iOS Device libraries: $(ls -1 "$BUILD_DIR/fat-ios"/*.a 2>/dev/null | wc -l) arquivos"
    echo "  Simulator libraries: $(ls -1 "$BUILD_DIR/fat-simulator"/*.a 2>/dev/null | wc -l) arquivos"
    echo -e "\n${GREEN}Tamanho das bibliotecas:${NC}"
    du -sh "$BUILD_DIR/fat-ios" "$BUILD_DIR/fat-simulator" 2>/dev/null || true
}

# Executa a função principal
main
