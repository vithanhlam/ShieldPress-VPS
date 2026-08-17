#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/ui.sh"

VERSION=$(cat "$BASE_DIR/version.txt" 2>/dev/null | tr -d '[:space:]')

clear
sp_hr
echo -e "${SP_CYAN}|${SP_RESET}                                                                            ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}        ${SP_BOLD}${SP_WHITE}███████╗██╗  ██╗██╗███████╗██╗     ██████╗${SP_RESET}                       ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}        ${SP_BOLD}${SP_WHITE}██╔════╝██║  ██║██║██╔════╝██║     ██╔══██╗${SP_RESET}                      ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}        ${SP_BOLD}${SP_WHITE}███████╗███████║██║█████╗  ██║     ██║  ██║${SP_RESET}                      ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}        ${SP_BOLD}${SP_WHITE}╚════██║██╔══██║██║██╔══╝  ██║     ██║  ██║${SP_RESET}                      ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}        ${SP_BOLD}${SP_WHITE}███████║██║  ██║██║███████╗███████╗██████╔╝${SP_RESET}                      ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}        ${SP_BOLD}${SP_WHITE}╚══════╝╚═╝  ╚═╝╚═╝╚══════╝╚══════╝╚═════╝${SP_RESET}                       ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}              ${SP_BOLD}${SP_GREEN}P R E S S${SP_RESET}   ${SP_DIM}VPS Management Platform${SP_RESET}                  ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}                                                                            ${SP_CYAN}|${SP_RESET}"
sp_hr
echo -e "${SP_CYAN}|${SP_RESET}                                                                            ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  ${SP_BOLD}About ShieldPress VPS${SP_RESET}                                                     ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}                                                                            ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  ShieldPress VPS is a lightweight, all-in-one server management            ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  platform designed to simplify the deployment and maintenance of            ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  web applications on Linux VPS. Built for WordPress, Laravel, and          ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  Node.js with enterprise-grade security, performance optimization,         ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  and self-healing capabilities.                                             ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}                                                                            ${SP_CYAN}|${SP_RESET}"
sp_hr
echo -e "${SP_CYAN}|${SP_RESET}                                                                            ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  ${SP_BOLD}Our Commitments${SP_RESET}                                                          ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}                                                                            ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  ${SP_GREEN}*${SP_RESET} 100% open source - no obfuscation, no encoded scripts.               ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}    Every line of code is fully readable and auditable.                      ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}                                                                            ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  ${SP_GREEN}*${SP_RESET} Zero data collection - we do NOT store, collect, or transmit          ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}    any of your personal information, server data, or credentials.           ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}    Your server is yours. Period.                                            ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}                                                                            ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  ${SP_GREEN}*${SP_RESET} Always by your side - we are committed to continuous support,          ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}    updates, and improvements. ShieldPress grows with you.                   ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}                                                                            ${SP_CYAN}|${SP_RESET}"
sp_hr
echo -e "${SP_CYAN}|${SP_RESET}                                                                            ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  ${SP_BOLD}Version${SP_RESET}  : ${SP_WHITE}${VERSION:-unknown}${SP_RESET}                                                     ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  ${SP_BOLD}Website${SP_RESET}  : ${SP_GREEN}https://shieldpress.net${SP_RESET}                                       ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  ${SP_BOLD}License${SP_RESET}  : ${SP_WHITE}GPLv3${SP_RESET}                                                         ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}                                                                            ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  ${SP_DIM}Thank you for choosing ShieldPress. We build tools we trust${SP_RESET}              ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}  ${SP_DIM}with our own servers - and we hope you will too.${SP_RESET}                         ${SP_CYAN}|${SP_RESET}"
echo -e "${SP_CYAN}|${SP_RESET}                                                                            ${SP_CYAN}|${SP_RESET}"
sp_hr
echo ""
read -p "Press Enter to go back..."
