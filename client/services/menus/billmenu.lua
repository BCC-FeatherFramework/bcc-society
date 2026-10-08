FeatherRPC:Register("bcc-society:OpenReceiptMenu", function(params)
    local myServerId = GetPlayerServerId(PlayerId())
    if params and params._target and params._target ~= myServerId then
        return -- Ignore if not meant for this player
    end

    DBG:Info("[Client] Opening receipt menu with:" .. json.encode(params))
    OpenReceiptMenu(params)
end)

function OpenReceiptMenu(receipt)
    local receiptPage = BCCSocietyMenu:RegisterPage("bcc-society:receiptPage")

    receiptPage:RegisterElement("header", {
        value = "📜 " .. _U("billReceipt"),
        slot = "header",
        style = {}
    })

    -- Clean formatting
    local amount = receipt.amount
    local from = receipt.paidFrom
    local to = receipt.paidTo
    local date = receipt.timestamp and ("" .. receipt.timestamp)
    local society = receipt.society
    local description = receipt.description
    local status = receipt.status

    local receiptHtml = [[
        <div style="padding: 50px; color: #e2c8a0; width: 100%; margin: 0 auto; box-shadow: 0 0 15px rgba(255,255,255,0.1); font-family: 'Courier New', monospace; background-color: rgba(0, 0, 0, 0.4); border-radius: 8px;">
            <hr style="border: 1px dashed #d4b890;">

            <p><strong style="color:#ffd59a;">]] .. _U("receiptFrom") .. [[</strong> <span style="color:#f3e0c7;">]] .. from .. [[</span></p>
            <p><strong style="color:#ffd59a;">]] .. _U("receiptTo") .. [[</strong> <span style="color:#f3e0c7;">]] .. to .. [[</span></p>
            <p><strong style="color:#f4b26d;">]] .. _U("receiptAmount") .. [[</strong> <span style="color:#ffffff;">$]] .. amount .. [[</span></p>
            <p><strong style="color:#f4b26d;">]] .. _U("receiptSociety") .. [[</strong> <span style="color:#ffffff;">]] .. society .. [[</span></p>
            <p><strong style="color:#efad74;">]] .. _U("receiptDate") .. [[</strong> <span style="color:#f3e0c7;">]] .. date .. [[</span></p>
            <p><strong style="color:#efad74;">]] .. _U("receiptDescription") .. [[</strong> <span style="color:#f3e0c7;">]] .. description .. [[</span></p>
            <p><strong style="color:#e3a861;">]] .. _U("receiptStatus") .. [[</strong> <span style="color: ]] .. (status == "PAID" and "#75ff90" or "#ff6e6e") .. [[;">]] .. status .. [[</span></p>
    
            <hr style="border: 1px dashed #d4b890;">
            <p style="text-align:center; font-size: 12px; color: #d4b890;">]] .. _U("receiptThankYou") .. [[</p>
        </div>
    ]]
    

    receiptPage:RegisterElement("html", {
        slot = "content",
        value = { receiptHtml }
    })

    receiptPage:RegisterElement("line", {
        slot = "footer",
        style = {}
    })

    receiptPage:RegisterElement("button", {
        label = _U("deleteReceipt"),
        slot = "footer",
        style = {}
    }, function()
        if receipt and receipt.id then
            FeatherRPC:Call("bcc-society:RevokeReceipt", {
                receiptId = receipt.id
            }, function(success, msg)
                if success then
                    Notify(_U("receiptDeleted"), "success", 4000)
                    BCCSocietyMenu:Close()
                else
                    Notify(_U(msg) or _U("receiptDeleteFailed"), "error", 4000)
                end
            end)
        else
            DBG:Warning("[Client] Invalid receipt or missing ID for deletion.")
            Notify(_U("invalidReceipt"), "error", 4000)
        end
    end)

    receiptPage:RegisterElement("button", {
        label = _U("close"),
        slot = "footer",
        style = {}
    }, function()
        BCCSocietyMenu:Close()
    end)

    receiptPage:RegisterElement("bottomline", {
        slot = "footer",
        style = {}
    })

    BCCSocietyMenu:Open({
        startupPage = receiptPage
    })
end

function OpenBillingMenu(societyData)
    local playerListPage = GetPlayerListMenuPage(false, function(data)
        DBG:Info("[BillingCommand] Selected target player:" .. data.source)

        local billAmountPage = BCCSocietyMenu:RegisterPage("bcc-society:billAmountPage")

        billAmountPage:RegisterElement("header", {
            value = _U("bill"),
            slot = "header",
            style = {}
        })

        local billAmount = ""
        billAmountPage:RegisterElement("input", {
            label = _U("amount"),
            placeholder = _U("placeholder"),
            style = {}
        }, function(data)
            billAmount = data.value
            DBG:Info("[BillingCommand] Bill amount entered:" .. billAmount)
        end)

        local billDescription = ""
        billAmountPage:RegisterElement("textarea", {
            label = _U("billDescriptionLabel") or "Description",
            placeholder = _U("billDescriptionPlaceholder") or "What is this bill for?",
            rows = "4",
            resize = false,
            style = {}
        }, function(data)
            billDescription = data.value
            DBG:Info("[BillingCommand] Bill description entered:" .. billDescription)
        end)
        billAmountPage:RegisterElement("line", {
            slot = "footer",
            style = {}
        })
        billAmountPage:RegisterElement("button", {
            label = _U("confirm"),
            slot = "footer",
            style = {}
        }, function()
            DBG:Info("[BillingCommand] Confirm pressed. Validating input...")

            if not string.find(billAmount, "-") and not string.find(billAmount, "'") and not string.find(billAmount, '"') then
                DBG:Info("[BillingCommand] Input is clean. Sending RPC: BillPlayer")

                FeatherRPC:Call("bcc-society:BillPlayer", {
                    playerServerId = data.source,
                    amount = billAmount,
                    description = billDescription,
                    societyId = societyData.business_id -- Add this!
                }, function(success, errorMsg)
                    if success then
                        DBG:Info("[BillingCommand] Bill sent.")
                        Notify(_U("billSent"), "success", 4000)
                    else
                        DBG:Error("[BillingCommand] Billing failed:" .. tostring(errorMsg))
                        Notify(errorMsg or _U("billingFailed"), "error", 4000)
                    end
                end)
                BCCSocietyMenu:Close()
            else
                DBG:Error("[BillingCommand] Input validation failed.")
                Notify(_U("inputProtectionError"), "error", 4000)
            end
        end)
        billAmountPage:RegisterElement("bottomline", {
            slot = "footer",
            style = {}
        })
        billAmountPage:RouteTo()
    end, function()
        DBG:Info("[BillingCommand] Player list menu closed.")
        BCCSocietyMenu:Close()
    end)

    BCCSocietyMenu:Open({
        startupPage = playerListPage
    })
end

-- A society billed this player: they accept or decline before any money moves.
FeatherRPC:Register("bcc-society:BillRequest", function(bill)
    local billRequestPage = BCCSocietyMenu:RegisterPage("bcc-society:billRequestPage")
    billRequestPage:RegisterElement("header", {
        value = _U("billRequest"),
        slot = "header",
        style = {}
    })
    billRequestPage:RegisterElement("textdisplay", {
        value = _U("receiptSociety") .. " " .. tostring(bill.society) .. "\n"
            .. _U("receiptFrom") .. " " .. tostring(bill.biller) .. "\n"
            .. _U("receiptAmount") .. " $" .. tostring(bill.amount) .. "\n"
            .. _U("receiptDescription") .. " " .. tostring(bill.description),
        style = {}
    })
    billRequestPage:RegisterElement("line", {
        slot = "footer",
        style = {}
    })
    billRequestPage:RegisterElement("button", {
        label = _U("payBill"),
        slot = "footer",
        style = {}
    }, function()
        BCCSocietyMenu:Close()
        FeatherRPC:Call("bcc-society:RespondBill", { billId = bill.id, accept = true })
    end)
    billRequestPage:RegisterElement("button", {
        label = _U("declineBill"),
        slot = "footer",
        style = {}
    }, function()
        BCCSocietyMenu:Close()
        FeatherRPC:Call("bcc-society:RespondBill", { billId = bill.id, accept = false })
    end)
    billRequestPage:RegisterElement("bottomline", {
        slot = "footer",
        style = {}
    })
    BCCSocietyMenu:Open({
        startupPage = billRequestPage
    })
end)

-- Paid receipts replace the old receipt item.
RegisterCommand(Config.receiptsCommandName, function()
    local receipts = FeatherRPC:CallAsync("bcc-society:GetMyReceipts", {})
    if type(receipts) ~= "table" or #receipts == 0 then
        Notify(_U("noReceipts"), "error", 4000)
        return
    end
    local receiptsPage = BCCSocietyMenu:RegisterPage("bcc-society:receiptsPage")
    receiptsPage:RegisterElement("header", {
        value = _U("billReceipt"),
        slot = "header",
        style = {}
    })
    for _, receipt in ipairs(receipts) do
        receiptsPage:RegisterElement("button", {
            label = ("%s - $%s (%s)"):format(tostring(receipt.society), tostring(receipt.amount), tostring(receipt.timestamp)),
            style = {}
        }, function()
            OpenReceiptMenu(receipt)
        end)
    end
    receiptsPage:RegisterElement("button", {
        label = _U("close"),
        slot = "footer",
        style = {}
    }, function()
        BCCSocietyMenu:Close()
    end)
    BCCSocietyMenu:Open({
        startupPage = receiptsPage
    })
end)
