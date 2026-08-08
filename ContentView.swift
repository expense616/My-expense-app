import SwiftUI
import Charts
import Foundation

// ==========================================
// 0. Supabase REST API 設定
// ==========================================
let supabaseURL = "https://ttyoomibbuxortbeucjm.supabase.co"
// 注意：確保這裡使用的是你的 anon / publishable key
let supabaseKey = "sb_publishable_DRlM9KrC2KFTVUoJI0dH2Q_u2c9PH10"

// 幣別中文對照字典
let currencyNames: [String: String] = [
    "TWD": "新台幣",
    "JPY": "日圓",
    "USD": "美元",
    "EUR": "歐元",
    "KRW": "韓元"
]

// ==========================================
// 1. 帳目資料結構 (Codable 支援，包含安全解碼)
// ==========================================
struct ExpenseItem: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var category: String
    var amount: Double        // 換算後的本國貨幣金額 (TWD)
    var date: Date
    
    var tags: [String]
    var currency: String      // 幣別: TWD, JPY, USD, EUR, KRW
    var foreignAmount: Double // 外幣原始金額
    var exchangeRate: Double  // 匯率
    
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case category
        case amount
        case date
        case tags
        case currency
        case foreignAmount = "foreign_amount"
        case exchangeRate = "exchange_rate"
    }
    
    init(
        id: UUID = UUID(),
        title: String,
        category: String,
        amount: Double,
        date: Date = Date(),
        tags: [String] = [],
        currency: String = "TWD",
        foreignAmount: Double? = nil,
        exchangeRate: Double = 1.0
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.amount = amount
        self.date = date
        self.tags = tags
        self.currency = currency
        self.foreignAmount = foreignAmount ?? amount
        self.exchangeRate = exchangeRate
    }
    
    // 安全解碼器：自動處理資料庫欄位格式不一致的問題
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        category = try container.decode(String.self, forKey: .category)
        amount = try container.decode(Double.self, forKey: .amount)
        date = try container.decode(Date.self, forKey: .date)
        
        // 處理 tags 欄位 (將資料庫的 text 自動轉回 Swift 的 Array)
        if let tagsString = try? container.decode(String.self, forKey: .tags) {
            tags = tagsString.split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
        } else if let tagsArray = try? container.decode([String].self, forKey: .tags) {
            tags = tagsArray
        } else {
            tags = []
        }
        
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "TWD"
        foreignAmount = try container.decodeIfPresent(Double.self, forKey: .foreignAmount) ?? amount
        exchangeRate = try container.decodeIfPresent(Double.self, forKey: .exchangeRate) ?? 1.0
    }
    
    // 安全編碼器：將 Swift Array 轉回 text 存進資料庫
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(category, forKey: .category)
        try container.encode(amount, forKey: .amount)
        try container.encode(date, forKey: .date)
        try container.encode(tags.joined(separator: ","), forKey: .tags)
        try container.encode(currency, forKey: .currency)
        try container.encode(foreignAmount, forKey: .foreignAmount)
        try container.encode(exchangeRate, forKey: .exchangeRate)
    }
    
    var iconName: String {
        switch category {
        case "餐飲": return "fork.knife"
        case "交通": return "bus.fill"
        case "購物": return "cart.fill"
        case "娛樂": return "gamecontroller.fill"
        case "保險": return "checkmark.shield.fill"
        case "居家": return "house.fill"
        case "醫藥": return "cross.case.fill"
        case "訂閱": return "tv.fill"
        default: return "bag.fill"
        }
    }
    
    var iconColor: Color {
        switch category {
        case "餐飲": return .orange
        case "交通": return .blue
        case "購物": return .pink
        case "娛樂": return .purple
        case "保險": return .teal
        case "居家": return .brown
        case "醫藥": return .red
        case "訂閱": return .indigo
        default: return .gray
        }
    }
}

// ==========================================
// 2. Supabase 網路請求助手 (REST API)
// ==========================================
class SupabaseService {
    static let shared = SupabaseService()
    
    private var headers: [String: String] {
        return [
            "apikey": supabaseKey,
            "Authorization": "Bearer \(supabaseKey)",
            "Content-Type": "application/json",
            "Prefer": "return=representation"
        ]
    }
    
    // 強固的日期解碼器
    private var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            
            let formatters = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ",
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy-MM-dd"
            ]
            
            for fmt in formatters {
                let formatter = DateFormatter()
                formatter.dateFormat = fmt
                formatter.locale = Locale(identifier: "en_US_POSIX")
                if let date = formatter.date(from: dateStr) {
                    return date
                }
            }
            return Date()
        }
        return decoder
    }
    
    private var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"
        encoder.dateEncodingStrategy = .formatted(formatter)
        return encoder
    }
    
    // 讀取資料 (指向單數 expense)
    func fetchExpenses() async throws -> [ExpenseItem] {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/expense?select=*") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "連線錯誤或資料表不存在"])
        }
        
        return try jsonDecoder.decode([ExpenseItem].self, from: data)
    }
    
    // 新增資料 (指向單數 expense)
    func insertExpense(_ item: ExpenseItem) async throws {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/expense") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        
        request.httpBody = try jsonEncoder.encode(item)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "新增雲端資料失敗"])
        }
    }
    
    // 更新資料 (指向單數 expense)
    func updateExpense(_ item: ExpenseItem) async throws {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/expense?id=eq.\(item.id.uuidString)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        
        request.httpBody = try jsonEncoder.encode(item)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "更新雲端資料失敗"])
        }
    }
    
    // 刪除資料 (指向單數 expense)
    func deleteExpense(id: UUID) async throws {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/expense?id=eq.\(id.uuidString)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "刪除雲端資料失敗"])
        }
    }
}

// ==========================================
// 3. 數字鍵盤面板
// ==========================================
struct CustomNumberPad: View {
    @Binding var value: String
    
    let buttons = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["C", "0", "⌫"]
    ]
    
    var body: some View {
        VStack(spacing: 6) { 
            ForEach(buttons, id: \.self) { row in
                HStack(spacing: 6) { 
                    ForEach(row, id: \.self) { btn in
                        Button(action: { buttonTapped(btn) }) {
                            Text(btn)
                                .font(.title2)
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity, maxHeight: 42) 
                                .background(btnColor(btn))
                                .foregroundColor(btnTextColor(btn))
                                .cornerRadius(8)
                        }
                    }
                }
            }
        }
        .padding(8) 
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    func buttonTapped(_ btn: String) {
        if btn == "⌫" {
            if !value.isEmpty { value.removeLast() }
        } else if btn == "C" {
            value = ""
        } else {
            if value == "0" { value = btn }
            else { value += btn }
        }
    }
    
    func btnColor(_ btn: String) -> Color {
        if btn == "⌫" || btn == "C" { return Color.red.opacity(0.15) }
        return Color(UIColor.systemBackground)
    }
    
    func btnTextColor(_ btn: String) -> Color {
        if btn == "⌫" || btn == "C" { return .red }
        return .primary
    }
}

// MARK: - 4. 圖表統計資料模型
struct CategorySummary: Identifiable {
    var id: String { category }
    let category: String
    let totalAmount: Double
    let color: Color
}

// ==========================================
// 5. 主畫面 (TabView) 與雲端同步邏輯
// ==========================================
struct ContentView: View {
    @State private var expenses: [ExpenseItem] = []
    @State private var monthlyBudget: Double = 20000.0
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        TabView {
            CalendarView(expenses: $expenses, monthlyBudget: $monthlyBudget, errorMessage: $errorMessage, onDataChange: {
                Task { await fetchExpenses() }
            })
            .tabItem {
                Label("消費紀錄", systemImage: "calendar")
            }
            
            ExpenseChartView(expenses: $expenses)
                .tabItem {
                    Label("消費統計", systemImage: "chart.pie.fill")
                }
        }
        .task {
            await fetchExpenses()
        }
    }
    
    func fetchExpenses() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await SupabaseService.shared.fetchExpenses()
            DispatchQueue.main.async {
                self.expenses = response
                self.isLoading = false
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "讀取失敗: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}

// ==========================================
// 6. 消費紀錄頁面 (支援原生左滑刪除)
// ==========================================
struct CalendarView: View {
    @Binding var expenses: [ExpenseItem]
    @Binding var monthlyBudget: Double
    @Binding var errorMessage: String?
    var onDataChange: () -> Void
    
    @State private var selectedDate = Date()
    @State private var isShowingAddSheet = false
    @State private var isShowingBudgetSheet = false
    @State private var itemToEdit: ExpenseItem? = nil
    @State private var selectedTagFilter: String? = nil
    
    var allTags: [String] {
        Array(Set(expenses.flatMap { $0.tags })).sorted()
    }
    
    var currentMonthTotal: Double {
        let calendar = Calendar.current
        return expenses.filter {
            calendar.isDate($0.date, equalTo: selectedDate, toGranularity: .month) &&
            calendar.isDate($0.date, equalTo: selectedDate, toGranularity: .year)
        }.reduce(0) { $0 + $1.amount }
    }
    
    var filteredExpenses: [ExpenseItem] {
        expenses.filter { item in
            let sameDay = Calendar.current.isDate(item.date, inSameDayAs: selectedDate)
            if let tag = selectedTagFilter {
                return sameDay && item.tags.contains(tag)
            }
            return sameDay
        }
    }
    
    var selectedDayTotal: Double {
        filteredExpenses.reduce(0) { $0 + $1.amount }
    }
    
    var budgetProgress: Double {
        guard monthlyBudget > 0 else { return 0 }
        return min(currentMonthTotal / monthlyBudget, 1.0)
    }
    
    var budgetColor: Color {
        if budgetProgress >= 1.0 { return .red }
        if budgetProgress >= 0.8 { return .orange }
        return .blue
    }
    
    func formatDateNumberOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy / MM / dd"
        return formatter.string(from: date)
    }
    
    func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            let itemToDelete = filteredExpenses[index]
            Task {
                try? await SupabaseService.shared.deleteExpense(id: itemToDelete.id)
                onDataChange()
            }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("記帳囉💸")
                            .font(.system(size: 28, weight: .bold))
                        Spacer()
                        Button(action: { isShowingBudgetSheet = true }) {
                            Image(systemName: "gearshape.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("本月預算控管")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("$\(currentMonthTotal, specifier: "%.0f") / $\(monthlyBudget, specifier: "%.0f")")
                                .font(.subheadline)
                                .fontWeight(.bold)
                        }
                        ProgressView(value: currentMonthTotal, total: max(monthlyBudget, 1.0))
                            .tint(budgetColor)
                    }
                    .padding(10)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(10)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(Color(UIColor.systemGroupedBackground))
                
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding()
                }
                
                ScrollView {
                    VStack(spacing: 10) {
                        DatePicker("選擇日期", selection: $selectedDate, displayedComponents: [.date])
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
                            .scaleEffect(0.92) // 微微縮小整顆行事曆，縮短內部元件間距
                            .frame(height: 310) // 固定合適的高度避免字體被裁切或上下留白過多
                            .padding(.vertical, -3) // 透過負邊距將上下多餘空間收緊
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(10)
                            .padding(.horizontal, 16)

                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center, spacing: 8) {
                                Text("消費明細 (\(filteredExpenses.count) 筆)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                if !allTags.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 4) {
                                            FilterChip(title: "全部", isSelected: selectedTagFilter == nil) {
                                                selectedTagFilter = nil
                                            }
                                            ForEach(allTags, id: \.self) { tag in
                                                FilterChip(title: "#\(tag)", isSelected: selectedTagFilter == tag) {
                                                    selectedTagFilter = (selectedTagFilter == tag) ? nil : tag
                                                }
                                            }
                                        }
                                    }
                                    .frame(maxWidth: 180)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 2)
                            
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(formatDateNumberOnly(selectedDate))
                                        .font(.caption)
                                    Text("當日總支出")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("$\(selectedDayTotal, specifier: "%.0f")")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundColor(.blue)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(UIColor.systemBackground))
                            .cornerRadius(8)
                            .shadow(color: .black.opacity(0.03), radius: 2, x: 0, y: 1)
                            .padding(.horizontal, 16)
                            
                            if filteredExpenses.isEmpty {
                                Text("這一天沒有消費紀錄～")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 20)
                            } else {
                                List {
                                    ForEach(filteredExpenses) { item in
                                        ExpenseRowView(item: item)
                                            .contentShape(Rectangle())
                                            .onTapGesture { itemToEdit = item }
                                    }
                                    .onDelete(perform: deleteItems)
                                }
                                .listStyle(.plain)
                                .frame(height: CGFloat(max(filteredExpenses.count * 64, 70)))
                                .cornerRadius(10)
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) {
                Button(action: { isShowingAddSheet = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                        Text("新增消費")
                            .font(.headline)
                            .fontWeight(.bold)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .cornerRadius(12)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .background(
                    Color(UIColor.systemGroupedBackground)
                        .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: -4)
                        .ignoresSafeArea()
                )
            }
            .sheet(isPresented: $isShowingAddSheet, onDismiss: { onDataChange() }) {
                AddExpenseView(expenses: $expenses, initialDate: selectedDate, onSave: { newItem in
                    Task {
                        try? await SupabaseService.shared.insertExpense(newItem)
                        onDataChange()
                    }
                })
            }
            .sheet(item: $itemToEdit, onDismiss: { onDataChange() }) { item in
                EditExpenseView(expenses: $expenses, itemToEdit: item, onUpdate: { updatedItem in
                    Task {
                        try? await SupabaseService.shared.updateExpense(updatedItem)
                        onDataChange()
                    }
                }, onDelete: { deletedId in
                    Task {
                        try? await SupabaseService.shared.deleteExpense(id: deletedId)
                        onDataChange()
                    }
                })
            }
            .sheet(isPresented: $isShowingBudgetSheet) {
                BudgetSettingView(budget: $monthlyBudget)
            }
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption2)
                .fontWeight(isSelected ? .bold : .regular)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isSelected ? Color.blue : Color(UIColor.tertiarySystemBackground))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(10)
        }
    }
}

struct ExpenseRowView: View {
    let item: ExpenseItem
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.iconName)
                .font(.caption)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(item.iconColor)
                .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline)
                
                HStack(spacing: 4) {
                    Text(item.category)
                        .font(.caption2)
                        .foregroundColor(.gray)
                    
                    ForEach(item.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 1) {
                Text("$\(item.amount, specifier: "%.0f") TWD")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                if item.currency != "TWD" {
                    let currencyName = currencyNames[item.currency] ?? ""
                    Text("(\(item.currency) \(currencyName) \(item.foreignAmount, specifier: "%.0f"))")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
        }
    }
}

// ==========================================
// 7. 消費統計頁面
// ==========================================
struct ExpenseChartView: View {
    @Binding var expenses: [ExpenseItem]
    @State private var selectedTab = 0 
    @State private var statMode = 0 
    @State private var selectedDate = Date()
    
    var totalAmount: Double {
        chartData.reduce(0) { $0 + $1.totalAmount }
    }
    
    var chartData: [CategorySummary] {
        let calendar = Calendar.current
        let filtered = expenses.filter { item in
            if selectedTab == 0 {
                return calendar.isDate(item.date, equalTo: selectedDate, toGranularity: .month) &&
                calendar.isDate(item.date, equalTo: selectedDate, toGranularity: .year)
            } else {
                return calendar.isDate(item.date, equalTo: selectedDate, toGranularity: .year)
            }
        }
        
        if statMode == 0 {
            let grouped = Dictionary(grouping: filtered, by: { $0.category })
            return grouped.map { (category, items) in
                let sum = items.reduce(0) { $0 + $1.amount }
                let color = items.first?.iconColor ?? .gray
                return CategorySummary(category: category, totalAmount: sum, color: color)
            }.sorted(by: { $0.totalAmount > $1.totalAmount })
        } else {
            var tagDict: [String: Double] = [:]
            for item in filtered {
                if item.tags.isEmpty {
                    tagDict["無標籤", default: 0] += item.amount
                } else {
                    for tag in item.tags {
                        tagDict[tag, default: 0] += item.amount
                    }
                }
            }
            
            let colors: [Color] = [.blue, .purple, .orange, .pink, .teal, .indigo, .cyan, .mint]
            var index = 0
            return tagDict.map { (tag, sum) in
                let color = colors[index % colors.count]
                index += 1
                return CategorySummary(category: "#\(tag)", totalAmount: sum, color: color)
            }.sorted(by: { $0.totalAmount > $1.totalAmount })
        }
    }
    
    var dateTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = (selectedTab == 0) ? "yyyy 年 MM 月" : "yyyy 年"
        return formatter.string(from: selectedDate)
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                Picker("統計模式", selection: $selectedTab) {
                    Text("按月統計").tag(0)
                    Text("按年統計").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                
                Picker("統計方式", selection: $statMode) {
                    Text("依類別統計").tag(0)
                    Text("依標籤統計").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                
                HStack {
                    Button(action: { changeDate(by: -1) }) {
                        Image(systemName: "chevron.left.circle.fill").font(.title2)
                    }
                    Spacer()
                    Text(dateTitle).font(.title3).fontWeight(.bold)
                    Spacer()
                    Button(action: { changeDate(by: 1) }) {
                        Image(systemName: "chevron.right.circle.fill").font(.title2)
                    }
                }
                .padding(.horizontal)
                
                VStack(spacing: 2) { 
                    Text(selectedTab == 0 ? "本月總支出" : "今年總支出")
                        .font(.subheadline).foregroundColor(.secondary)
                    Text("$\(totalAmount, specifier: "%.0f")")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.blue)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
                
                if chartData.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "chart.pie").font(.system(size: 40)).foregroundColor(.gray.opacity(0.5))
                        Text("該時段沒有消費紀錄～").foregroundColor(.gray)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 16) { 
                            Chart(chartData) { item in
                                SectorMark(
                                    angle: .value("金額", item.totalAmount),
                                    innerRadius: .ratio(0.5),
                                    angularInset: 1.5
                                )
                                .cornerRadius(5)
                                .foregroundStyle(item.color)
                            }
                            .frame(height: 180)
                            .padding(.top, 8)
                            
                            VStack(spacing: 8) { 
                                ForEach(chartData) { item in
                                    HStack {
                                        Circle().fill(item.color).frame(width: 12, height: 12)
                                        Text(item.category).font(.body)
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 0) {
                                            Text("$\(item.totalAmount, specifier: "%.0f")").font(.body)
                                            if totalAmount > 0 {
                                                Text("\(item.totalAmount / totalAmount * 100, specifier: "%.1f")%")
                                                    .font(.caption).foregroundColor(.gray)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(10)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 15, coordinateSpace: .local)
                    .onEnded { value in
                        let horizontalAmount = value.translation.width
                        let verticalAmount = value.translation.height
                        if abs(horizontalAmount) > abs(verticalAmount) * 0.8 {
                            if horizontalAmount < -20 { changeDate(by: 1) }
                            else if horizontalAmount > 20 { changeDate(by: -1) }
                        }
                    }
            )
            .padding(.top, 8)
            .navigationTitle("消費統計")
            .navigationBarTitleDisplayMode(.inline) 
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        }
    }
    
    func changeDate(by value: Int) {
        withAnimation(.easeInOut(duration: 0.25)) {
            let calendar = Calendar.current
            let component: Calendar.Component = (selectedTab == 0) ? .month : .year
            if let newDate = calendar.date(byAdding: component, value: value, to: selectedDate) {
                selectedDate = newDate
            }
        }
    }
}

// ==========================================
// 8. 新增消費頁面
// ==========================================
struct AddExpenseView: View {
    @Binding var expenses: [ExpenseItem]
    var initialDate: Date
    var onSave: (ExpenseItem) -> Void
    @Environment(\.dismiss) var dismiss
    
    @State private var title = ""
    @State private var amount = ""
    @State private var category = "餐飲"
    @State private var tagInput = ""
    @State private var expenseDate: Date
    
    @State private var selectedCurrency = "TWD"
    @State private var exchangeRateText = "1.0"
    let currencies = ["TWD", "JPY", "USD", "EUR", "KRW"]
    let defaultRates: [String: Double] = ["TWD": 1.0, "JPY": 0.218, "USD": 32.2, "EUR": 34.8, "KRW": 0.024]
    
    init(expenses: Binding<[ExpenseItem]>, initialDate: Date, onSave: @escaping (ExpenseItem) -> Void) {
        self._expenses = expenses
        self.initialDate = initialDate
        self.onSave = onSave
        self._expenseDate = State(initialValue: initialDate)
    }
    
    let categories = ["餐飲", "交通", "購物", "娛樂", "保險", "居家", "醫藥", "訂閱", "其他"]
    
    var calculatedTWDAmount: Double {
        let rawAmount = Double(amount) ?? 0
        let rate = Double(exchangeRateText) ?? 1.0
        return rawAmount * rate
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) { 
                Form {
                    Section(header: Text("消費資訊")) {
                        TextField("買了什麼 (例如：拉麵)", text: $title)
                        
                        Picker("幣別", selection: $selectedCurrency) {
                            ForEach(currencies, id: \.self) { c in 
                                Text("\(c) (\(currencyNames[c] ?? ""))").tag(c) 
                            }
                        }
                        .onChange(of: selectedCurrency) { oldValue, newCurrency in
                            exchangeRateText = String(defaultRates[newCurrency] ?? 1.0)
                        }
                        
                        if selectedCurrency != "TWD" {
                            HStack {
                                Text("匯率 (1 \(selectedCurrency) = ? TWD)")
                                Spacer()
                                TextField("匯率", text: $exchangeRateText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                            }
                        }
                        
                        HStack {
                            Text("金額 (\(selectedCurrency) \(currencyNames[selectedCurrency] ?? ""))")
                            Spacer()
                            Text(amount.isEmpty ? "0" : amount)
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.blue)
                        }
                        
                        if selectedCurrency != "TWD" {
                            HStack {
                                Text("折合台幣約")
                                Spacer()
                                Text("$\(calculatedTWDAmount, specifier: "%.0f") TWD")
                                    .foregroundColor(.gray)
                            }
                        }
                        
                        Picker("類別", selection: $category) {
                            ForEach(categories, id: \.self) { cat in Text(cat) }
                        }
                        
                        TextField("新增標籤 (多個請用空格分開，如：旅遊 聚餐)", text: $tagInput)
                        
                        DatePicker("消費日期", selection: $expenseDate, displayedComponents: [.date])
                            .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
                    }
                }
                
                CustomNumberPad(value: $amount)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .padding(.top, 4) 
            }
            .navigationTitle("新增一筆消費")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { saveExpense() }
                }
            }
        }
    }
    
    func saveExpense() {
        let rawAmount = Double(amount) ?? 0
        let rate = Double(exchangeRateText) ?? 1.0
        let twdAmount = rawAmount * rate
        let tags = tagInput.components(separatedBy: " ").filter { !$0.isEmpty }
        
        if rawAmount > 0, !title.isEmpty {
            let newItem = ExpenseItem(
                title: title,
                category: category,
                amount: twdAmount,
                date: expenseDate,
                tags: tags,
                currency: selectedCurrency,
                foreignAmount: rawAmount,
                exchangeRate: rate
            )
            onSave(newItem)
            dismiss()
        }
    }
}

// ==========================================
// 9. 修改消費頁面
// ==========================================
struct EditExpenseView: View {
    @Binding var expenses: [ExpenseItem]
    var itemToEdit: ExpenseItem
    var onUpdate: (ExpenseItem) -> Void
    var onDelete: (UUID) -> Void
    @Environment(\.dismiss) var dismiss
    
    @State private var title: String
    @State private var amount: String
    @State private var category: String
    @State private var tagInput: String
    @State private var expenseDate: Date
    
    init(expenses: Binding<[ExpenseItem]>, itemToEdit: ExpenseItem, onUpdate: @escaping (ExpenseItem) -> Void, onDelete: @escaping (UUID) -> Void) {
        self._expenses = expenses
        self.itemToEdit = itemToEdit
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self._title = State(initialValue: itemToEdit.title)
        self._amount = State(initialValue: String(format: "%.0f", itemToEdit.foreignAmount))
        self._category = State(initialValue: itemToEdit.category)
        self._tagInput = State(initialValue: itemToEdit.tags.joined(separator: " "))
        self._expenseDate = State(initialValue: itemToEdit.date)
    }
    
    let categories = ["餐飲", "交通", "購物", "娛樂", "保險", "居家", "醫藥", "訂閱", "其他"]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Form {
                    Section(header: Text("修改內容")) {
                        TextField("買了什麼", text: $title)
                        
                        HStack {
                            let currencyName = currencyNames[itemToEdit.currency] ?? ""
                            Text("金額 (\(itemToEdit.currency) \(currencyName))")
                            Spacer()
                            Text(amount.isEmpty ? "0" : amount)
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.blue)
                        }
                        
                        Picker("類別", selection: $category) {
                            ForEach(categories, id: \.self) { cat in Text(cat) }
                        }
                        
                        TextField("標籤 (以空格分隔)", text: $tagInput)
                        
                        DatePicker("消費日期", selection: $expenseDate, displayedComponents: [.date])
                            .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
                    }
                    
                    Section {
                        Button(role: .destructive, action: deleteItem) {
                            HStack {
                                Spacer()
                                Text("刪除此筆消費")
                                Spacer()
                            }
                        }
                    }
                }
                
                CustomNumberPad(value: $amount)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .padding(.top, 4)
            }
            .navigationTitle("修改帳目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("儲存修改") { saveChanges() } }
            }
        }
    }
    
    func saveChanges() {
        let rawAmount = Double(amount) ?? 0
        if !title.isEmpty {
            var updatedItem = itemToEdit
            let rate = updatedItem.exchangeRate
            updatedItem.title = title
            updatedItem.foreignAmount = rawAmount
            updatedItem.amount = rawAmount * rate
            updatedItem.category = category
            updatedItem.tags = tagInput.components(separatedBy: " ").filter { !$0.isEmpty }
            updatedItem.date = expenseDate
            
            onUpdate(updatedItem)
            dismiss()
        }
    }
    
    func deleteItem() {
        onDelete(itemToEdit.id)
        dismiss()
    }
}

// ==========================================
// 10. 預算設定彈窗
// ==========================================
struct BudgetSettingView: View {
    @Binding var budget: Double
    @Environment(\.dismiss) var dismiss
    @State private var budgetInput: String = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Form {
                    Section(header: Text("設定每月預算上限")) {
                        HStack {
                            Text("預算金額")
                            Spacer()
                            Text(budgetInput.isEmpty ? "0" : budgetInput)
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.blue)
                        }
                    }
                }
                
                CustomNumberPad(value: $budgetInput)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .padding(.top, 4)
            }
            .navigationTitle("預算設定")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { budgetInput = String(format: "%.0f", budget) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        if let val = Double(budgetInput) { budget = val }
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}

